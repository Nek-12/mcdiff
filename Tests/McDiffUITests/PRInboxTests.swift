import McDiffCore
import XCTest
@testable import McDiff

private actor PagedInboxLoader {
    struct Call: Equatable {
        let query: String
        let page: Int
    }
    private(set) var calls: [Call] = []
    var failures: Set<Int> = []
    var paused = false
    var totalCount = 1_000
    private var pending: [Int: CheckedContinuation<PRPage, Error>] = [:]

    func configure(failures: Set<Int> = [], paused: Bool = false) {
        self.failures = failures
        self.paused = paused
    }

    func setTotalCount(_ count: Int) { totalCount = count }

    func load(_ query: String, _ page: Int) async throws -> PRPage {
        let index = calls.count
        calls.append(Call(query: query, page: page))
        if paused {
            return try await withCheckedThrowingContinuation { pending[index] = $0 }
        }
        if failures.contains(page) { throw GitHubError.network(-1009) }
        return try Self.page(page, query: query, totalCount: totalCount)
    }

    func complete(_ index: Int) throws {
        let call = calls[index]
        pending.removeValue(forKey: index)?.resume(returning: try Self.page(call.page, query: call.query, totalCount: totalCount))
    }

    static func page(_ number: Int, query: String = "", totalCount: Int = 1_000) throws -> PRPage {
        let start = (number - 1) * PRPage.pageSize
        return PRPage(items: try (start..<max(start, min(totalCount, start + PRPage.pageSize))).map {
            PRSummary(pr: try GitHubPR.parse("https://github.com/owner/repo/pull/\($0 + 1)"),
                      title: "\(query) PR \($0 + 1)", createdAt: Date(timeIntervalSince1970: Double($0)),
                      isDraft: $0.isMultiple(of: 2))
        }, totalCount: totalCount)
    }
}

final class PRInboxTests: XCTestCase {
    @MainActor
    private func waitFor(_ predicate: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<600 {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for inbox", file: file, line: line)
    }

    @MainActor
    func testForwardBackwardAndJumpUseBoundedProjectionAndSQLiteCache() async throws {
        let loader = PagedInboxLoader()
        let inbox = PRInbox { try await loader.load($0, $1) }
        inbox.refresh()
        XCTAssertTrue(inbox.isLoading)
        await waitFor { !inbox.isLoading }
        XCTAssertNil(inbox.error)
        XCTAssertEqual(inbox.count, 1_000)
        XCTAssertEqual(inbox.item(at: 0)?.pr.number, 1)
        var calls = await loader.calls
        XCTAssertEqual(calls.map(\.page), [1, 2])
        inbox.show(30..<60)
        await waitFor { !inbox.isLoading }
        calls = await loader.calls
        XCTAssertEqual(calls.map(\.page), [1, 2, 3])
        inbox.show(900..<930)
        await waitFor { !inbox.isLoading }
        calls = await loader.calls
        XCTAssertEqual(calls.map(\.page), [1, 2, 3, 31, 30, 32])
        XCTAssertNil(inbox.item(at: 0))
        XCTAssertEqual(inbox.item(at: 900)?.pr.number, 901)
        XCTAssertLessThanOrEqual((0..<inbox.count).compactMap(inbox.item(at:)).count, 150)
        inbox.show(0..<30)
        await waitFor { !inbox.isLoading }
        let afterReturn = await loader.calls
        XCTAssertEqual(afterReturn, calls)
        XCTAssertEqual(inbox.item(at: 0)?.title, " PR 1")
        XCTAssertEqual(inbox.item(at: 0)?.isDraft, true)
        XCTAssertEqual(inbox.item(at: 0)?.createdAt, Date(timeIntervalSince1970: 0))
        inbox.show(0..<1_000)
        await waitFor { !inbox.isLoading }
        XCTAssertLessThanOrEqual((0..<inbox.count).compactMap(inbox.item(at:)).count, 150)
        inbox.show(990..<1_010)
        await waitFor { !inbox.isLoading }
        XCTAssertNotNil(inbox.item(at: 999))
        XCTAssertNil(inbox.item(at: 1_000))
        XCTAssertNil(inbox.error)
    }

    @MainActor
    func testTransientFailurePreservesRowsAndRetryFetchesOnlyMissingPages() async throws {
        let loader = PagedInboxLoader()
        await loader.configure(failures: [2])
        let inbox = PRInbox { try await loader.load($0, $1) }
        inbox.refresh()
        await waitFor { !inbox.isLoading }
        XCTAssertNotNil(inbox.error)
        XCTAssertNotNil(inbox.item(at: 0))
        XCTAssertNil(inbox.item(at: 30))
        await loader.configure()
        inbox.retry()
        await waitFor { !inbox.isLoading }
        XCTAssertNil(inbox.error)
        XCTAssertNotNil(inbox.item(at: 30))
        let calls = await loader.calls
        XCTAssertEqual(calls.map(\.page), [1, 2, 2])
        await loader.configure(failures: [1])
        inbox.refresh()
        XCTAssertNotNil(inbox.item(at: 0))
        await waitFor { !inbox.isLoading }
        XCTAssertNotNil(inbox.error)
        XCTAssertNotNil(inbox.item(at: 0), "Failed refresh preserves same-query content")
        await loader.configure()
        inbox.retry()
        await waitFor { !inbox.isLoading }
        XCTAssertNil(inbox.error)
    }

    @MainActor
    func testSearchDebouncesAndRejectsLateQueryResults() async throws {
        let loader = PagedInboxLoader()
        await loader.configure(paused: true)
        let inbox = PRInbox { try await loader.load($0, $1) }
        inbox.refresh()
        await waitFor { await loader.calls.count == 1 }
        inbox.search("first")
        XCTAssertTrue(inbox.isLoading)
        XCTAssertEqual(inbox.count, 0)
        inbox.search("second")
        try await loader.complete(0)
        await waitFor { await loader.calls.count == 2 }
        let calls = await loader.calls
        XCTAssertEqual(calls.map(\.query), ["", "second"])
        XCTAssertNil(inbox.item(at: 0))
        try await loader.complete(1)
        await waitFor { await loader.calls.count == 3 }
        try await loader.complete(2)
        await waitFor { !inbox.isLoading }
        XCTAssertEqual(inbox.item(at: 0)?.title, "second PR 1")
        XCTAssertNil(inbox.error)
    }

    @MainActor
    func testViewportRetargetRejectsLateRowsAndClearRejectsLateAccountResults() async throws {
        let loader = PagedInboxLoader()
        let inbox = PRInbox { try await loader.load($0, $1) }
        inbox.refresh()
        await waitFor { !inbox.isLoading }
        await loader.configure(paused: true)
        inbox.show(300..<330)
        await waitFor { await loader.calls.count == 3 }
        inbox.show(600..<630)
        try await loader.complete(2)
        await waitFor { await loader.calls.count == 4 }
        XCTAssertNil(inbox.item(at: 300))
        inbox.clear()
        try await loader.complete(3)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(inbox.count, 0)
        XCTAssertFalse(inbox.isLoading)
        XCTAssertNil(inbox.error)
        XCTAssertNil(inbox.item(at: 600))
        await loader.configure()
        inbox.refresh()
        await waitFor { !inbox.isLoading }
        XCTAssertNotNil(inbox.item(at: 0))
    }

    @MainActor
    func testEmptyAndAuthenticationFailureAreExplicit() async {
        let empty = PRInbox { _, _ in PRPage(items: [], totalCount: 0) }
        empty.refresh()
        await waitFor { !empty.isLoading }
        XCTAssertEqual(empty.count, 0)
        XCTAssertNil(empty.error)
        let unauthorized = PRInbox { _, _ in throw GitHubError.unauthenticated }
        var requested = false
        unauthorized.onAuthenticationRequired = { requested = true }
        unauthorized.refresh()
        await waitFor { !unauthorized.isLoading }
        XCTAssertTrue(requested)
        XCTAssertNotNil(unauthorized.error)
    }

    @MainActor
    func testChangeCallbackCanRetargetViewportWithoutOrphaningWork() async throws {
        let loader = PagedInboxLoader()
        let inbox = PRInbox { try await loader.load($0, $1) }
        inbox.onChange = {
            if inbox.count > 0 { inbox.show(600..<630) }
        }
        inbox.refresh()
        await waitFor { !inbox.isLoading }
        XCTAssertNil(inbox.error)
        XCTAssertNotNil(inbox.item(at: 600))
        XCTAssertNil(inbox.item(at: 0))
        inbox.onChange = nil
        let calls = await loader.calls
        XCTAssertEqual(calls.map(\.page), [1, 21, 20, 22])
    }

    @MainActor
    func testSmallViewportMovementsKeepPendingPageRequest() async throws {
        let loader = PagedInboxLoader()
        let inbox = PRInbox { try await loader.load($0, $1) }
        inbox.refresh()
        await waitFor { !inbox.isLoading }
        await loader.configure(paused: true)
        inbox.show(601..<611)
        await waitFor { await loader.calls.count == 3 }
        for start in 602...610 { inbox.show(start..<(start + 10)) }
        await loader.configure()
        try await loader.complete(2)
        await waitFor { !inbox.isLoading }
        let calls = await loader.calls
        XCTAssertEqual(calls.map(\.page), [1, 2, 21, 20, 22])
        XCTAssertNotNil(inbox.item(at: 619))
        XCTAssertNil(inbox.error)
    }

    @MainActor
    func testRefreshAfterCountShrinksFetchesClampedDestination() async throws {
        let loader = PagedInboxLoader()
        let inbox = PRInbox { try await loader.load($0, $1) }
        inbox.refresh()
        await waitFor { !inbox.isLoading }
        inbox.show(900..<930)
        await waitFor { !inbox.isLoading }
        await loader.setTotalCount(10)
        inbox.refresh()
        await waitFor { !inbox.isLoading }
        XCTAssertEqual(inbox.count, 10)
        XCTAssertNotNil(inbox.item(at: 0))
        XCTAssertNotNil(inbox.item(at: 9))
        XCTAssertNil(inbox.item(at: 900))
        XCTAssertNil(inbox.error)
        let calls = await loader.calls
        XCTAssertEqual(calls.suffix(2).map(\.page), [31, 1])
        await loader.setTotalCount(0)
        inbox.refresh()
        await waitFor { !inbox.isLoading }
        XCTAssertEqual(inbox.count, 0)
        XCTAssertNil(inbox.item(at: 0))
        XCTAssertNil(inbox.error)
    }

    @MainActor
    func testInvalidPageBoundsAreObservableFailures() async throws {
        let valid = try PagedInboxLoader.page(1)
        for page in [
            PRPage(items: [], totalCount: -1),
            PRPage(items: [], totalCount: 1_001),
            PRPage(items: valid.items + [valid.items[0]], totalCount: 100)
        ] {
            let inbox = PRInbox { _, _ in page }
            inbox.refresh()
            await waitFor { !inbox.isLoading }
            XCTAssertNotNil(inbox.error)
            XCTAssertEqual(inbox.count, 0)
            XCTAssertNil(inbox.item(at: 0))
        }
    }
}
