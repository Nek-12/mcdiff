import AppKit
import McDiffCore
import XCTest
@testable import McDiff

private actor InboxLoader {
    struct Request: Equatable {
        let query: String
        let page: Int
    }
    var requests: [Request] = []
    private var continuations: [Int: CheckedContinuation<PRPage, Error>] = [:]
    func load(_ query: String, _ page: Int) async throws -> PRPage {
        let index = requests.count
        requests.append(Request(query: query, page: page))
        return try await withCheckedThrowingContinuation { continuations[index] = $0 }
    }
    func complete(_ index: Int, _ result: Result<PRPage, Error>) {
        continuations.removeValue(forKey: index)?.resume(with: result)
    }
}

final class PRHomeTests: XCTestCase {
    private func page(_ numbers: [Int], hasNext: Bool = false) throws -> PRPage {
        PRPage(items: try numbers.map {
            PRSummary(pr: try GitHubPR.parse("https://github.com/owner/repo/pull/\($0)"),
                      title: "Pull request \($0)", createdAt: Date(), isDraft: false)
        }, hasNext: hasNext)
    }

    @MainActor
    private func waitFor(_ predicate: () async -> Bool) async {
        for _ in 0..<400 {
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
    private func text(_ home: PRHomeController) -> String {
        descendants(home.view).compactMap { $0 as? NSTextField }.map(\.stringValue).joined(separator: "\n")
    }

    @MainActor
    private func search(_ query: String, in home: PRHomeController) {
        home.searchItem.searchField.stringValue = query
        home.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                             object: home.searchItem.searchField))
    }

    @MainActor
    func testLoadingIsExplicitDeduplicatedAndEmptyResultIsVisible() async throws {
        _ = NSApplication.shared
        let loader = InboxLoader()
        let home = PRHomeController { try await loader.load($0, $1) }
        _ = home.view
        let initial = await loader.requests
        XCTAssertTrue(initial.isEmpty)
        home.refresh()
        XCTAssertTrue(home.isLoading)
        home.refresh()
        await waitFor { await loader.requests.count == 1 }
        await loader.complete(0, .success(try page([])))
        await waitFor { !home.isLoading }
        XCTAssertTrue(home.results.isEmpty)
        XCTAssertTrue(text(home).contains("No open pull requests"))
        XCTAssertFalse(try button("Previous", in: home).isEnabled)
        XCTAssertFalse(try button("Next", in: home).isEnabled)
        var opened = false
        home.onOpenPR = { _ in opened = true }
        home.openSelected()
        XCTAssertFalse(opened)
    }

    @MainActor
    func testPaginationReplacesPageAndRefreshesCurrentPage() async throws {
        _ = NSApplication.shared
        let loader = InboxLoader()
        let home = PRHomeController { try await loader.load($0, $1) }
        home.refresh()
        await waitFor { await loader.requests.count == 1 }
        await loader.complete(0, .success(try page([1, 2], hasNext: true)))
        await waitFor { !home.isLoading }
        XCTAssertFalse(try button("Previous", in: home).isEnabled)
        try button("Next", in: home).performClick(nil)
        XCTAssertTrue(home.isLoading)
        XCTAssertTrue(home.results.isEmpty, "Do not present an older page as the requested page during loading")
        XCTAssertFalse(try button("Next", in: home).isEnabled)
        await waitFor { await loader.requests.count == 2 }
        await loader.complete(1, .success(try page([3])))
        await waitFor { !home.isLoading }
        XCTAssertEqual(home.results.map(\.pr.number), [3])
        XCTAssertTrue(text(home).contains("Page 2"))
        XCTAssertFalse(try button("Next", in: home).isEnabled)
        home.nextPage()
        home.refresh()
        await waitFor { await loader.requests.count == 3 }
        await loader.complete(2, .success(try page([4])))
        await waitFor { !home.isLoading }
        try button("Previous", in: home).performClick(nil)
        await waitFor { await loader.requests.count == 4 }
        await loader.complete(3, .success(try page([1, 2], hasNext: true)))
        await waitFor { !home.isLoading }
        let requests = await loader.requests
        XCTAssertEqual(requests.map(\.page), [1, 2, 2, 1])
        XCTAssertEqual(home.results.map(\.pr.number), [1, 2])
    }

    @MainActor
    func testServerSearchDebouncesResetsPageAndPaginatesBeyondFirstPage() async throws {
        _ = NSApplication.shared
        let loader = InboxLoader()
        let home = PRHomeController { try await loader.load($0, $1) }
        home.refresh()
        await waitFor { await loader.requests.count == 1 }
        await loader.complete(0, .success(try page([1], hasNext: true)))
        await waitFor { !home.isLoading }
        home.nextPage()
        await waitFor { await loader.requests.count == 2 }
        await loader.complete(1, .success(try page([2])))
        await waitFor { !home.isLoading }
        search("partial", in: home)
        XCTAssertTrue(home.isLoading, "Loading feedback starts before the debounce expires")
        XCTAssertTrue(home.results.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        let beforeDebounce = await loader.requests
        XCTAssertEqual(beforeDebounce.count, 2)
        search("server query", in: home)
        await waitFor { await loader.requests.count == 3 }
        await loader.complete(2, .success(try page([300], hasNext: true)))
        await waitFor { !home.isLoading }
        // This title does not contain the query: the server result must not be filtered locally.
        XCTAssertEqual(home.results.map(\.pr.number), [300])
        home.nextPage()
        await waitFor { await loader.requests.count == 4 }
        await loader.complete(3, .success(try page([301])))
        await waitFor { !home.isLoading }
        home.refresh()
        await waitFor { await loader.requests.count == 5 }
        await loader.complete(4, .success(try page([302])))
        await waitFor { !home.isLoading }
        let requests = await loader.requests
        XCTAssertEqual(requests.map(\.query), ["", "", "server query", "server query", "server query"])
        XCTAssertEqual(requests.map(\.page), [1, 2, 1, 2, 2])
        XCTAssertEqual(home.results.map(\.pr.number), [302])
        search("", in: home)
        await waitFor { await loader.requests.count == 6 }
        await loader.complete(5, .success(try page([1])))
        await waitFor { !home.isLoading }
        let last = await loader.requests.last
        XCTAssertEqual(last, InboxLoader.Request(query: "", page: 1))
    }

    @MainActor
    func testLateResponsesCannotOverwriteNewSearchOrItsLoadingState() async throws {
        _ = NSApplication.shared
        let loader = InboxLoader()
        let home = PRHomeController { try await loader.load($0, $1) }
        home.refresh()
        await waitFor { await loader.requests.count == 1 }
        search("new", in: home)
        await waitFor { await loader.requests.count == 2 }
        await loader.complete(0, .success(try page([1])))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(home.isLoading)
        XCTAssertTrue(home.results.isEmpty)
        await loader.complete(1, .success(try page([2])))
        await waitFor { !home.isLoading }
        search("old request", in: home)
        await waitFor { await loader.requests.count == 3 }
        search("latest", in: home)
        await waitFor { await loader.requests.count == 4 }
        await loader.complete(3, .success(try page([4])))
        await waitFor { !home.isLoading }
        await loader.complete(2, .failure(NSError(domain: "obsolete", code: 1)))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(home.results.map(\.pr.number), [4])
        XCTAssertFalse(text(home).contains("obsolete"))
        XCTAssertTrue(try button("Retry", in: home).isHidden)
    }

    @MainActor
    func testErrorIdentifiesOldQueryAndRetryUsesFailedRequestWithoutAutoOpening() async throws {
        _ = NSApplication.shared
        let loader = InboxLoader()
        let home = PRHomeController { try await loader.load($0, $1) }
        var opened: [String] = []
        home.onOpenPR = { opened.append($0) }
        search("first", in: home)
        await waitFor { await loader.requests.count == 1 }
        await loader.complete(0, .success(try page([1], hasNext: true)))
        await waitFor { !home.isLoading }
        home.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        search("second", in: home)
        await waitFor { await loader.requests.count == 2 }
        await loader.complete(1, .failure(NSError(domain: "offline", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Connection is offline"])))
        await waitFor { !home.isLoading }
        XCTAssertEqual(home.results.map(\.pr.number), [1])
        XCTAssertTrue(text(home).contains("Couldn’t load page 1 for “second”"))
        XCTAssertTrue(text(home).contains("Showing previously loaded page 1 for “first”"))
        XCTAssertTrue(text(home).contains("Connection is offline"))
        XCTAssertFalse(try button("Next", in: home).isEnabled)
        XCTAssertTrue(opened.isEmpty)
        try button("Retry", in: home).performClick(nil)
        await waitFor { await loader.requests.count == 3 }
        await loader.complete(2, .success(try page([2])))
        await waitFor { !home.isLoading }
        XCTAssertTrue(opened.isEmpty)
        let requests = await loader.requests
        XCTAssertEqual(requests.map(\.query), ["first", "second", "second"])
        XCTAssertEqual(home.table.selectedRow, -1)
        home.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        home.table.keyDown(with: enter)
        XCTAssertEqual(opened, ["https://github.com/owner/repo/pull/2"])
    }

    @MainActor
    func testRefreshFailureKeepsPageAndSelectionWithExplicitStaleStatus() async throws {
        _ = NSApplication.shared
        let loader = InboxLoader()
        let home = PRHomeController { try await loader.load($0, $1) }
        home.refresh()
        await waitFor { await loader.requests.count == 1 }
        await loader.complete(0, .success(try page([1, 2])))
        await waitFor { !home.isLoading }
        var opened = false
        home.onOpenPR = { _ in opened = true }
        home.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        home.refresh()
        XCTAssertEqual(home.results.map(\.pr.number), [1, 2])
        await waitFor { await loader.requests.count == 2 }
        await loader.complete(1, .failure(NSError(domain: "offline", code: 1)))
        await waitFor { !home.isLoading }
        XCTAssertEqual(home.results.map(\.pr.number), [1, 2])
        XCTAssertEqual(home.table.selectedRow, 1)
        XCTAssertTrue(text(home).contains("Showing previously loaded page 1."))
        XCTAssertFalse(opened)
        home.retry()
        await waitFor { await loader.requests.count == 3 }
        await loader.complete(2, .success(try page([2, 3])))
        await waitFor { !home.isLoading }
        XCTAssertEqual(home.table.selectedRow, 0)
        XCTAssertFalse(opened)
        XCTAssertFalse(text(home).contains("Showing previously loaded"))
    }

    @MainActor
    func testResumeAction() throws {
        _ = NSApplication.shared
        let home = PRHomeController { _, _ in PRPage(items: [], hasNext: false) }
        var resumed = false
        home.onResume = { resumed = true }
        home.resumeTitle = "owner/repo"
        try button("Resume owner/repo", in: home).performClick(nil)
        XCTAssertTrue(resumed)
        home.resumeTitle = nil
        XCTAssertTrue(try button("", in: home).isHidden)
    }
}
