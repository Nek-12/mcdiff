import AppKit
import XCTest
@testable import McDiff
@testable import McDiffCore

final class HomeIntegrationTests: XCTestCase {
    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor
    private func waitFor(_ predicate: () -> Bool) async {
        for _ in 0..<400 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for Home")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    func testFreshStartIgnoresRecentAndOffersSignedOutHomeAndLocalComparison() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReviewStore(directory: directory)
        try store.savePreferences(ReviewPreferences(recentComparisons: [
            ComparisonRequest(repository: "/nonexistent", base: "main")
        ]))
        let controller = ReviewWindowController(github: GitHubClient(clientID: "test", credentials: EmptyHomeCredentials()))
        controller.start(store: store, arguments: [])
        let window = try XCTUnwrap(controller.window)
        window.isReleasedWhenClosed = false
        defer { window.delegate = nil; controller.close() }
        await waitFor { window.toolbar?.items.contains { $0.label == "Sign in to GitHub" } == true }
        XCTAssertEqual(controller.screen, .home)
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(controller.home.results.isEmpty)
        XCTAssertTrue(window.toolbar!.items.contains { $0 === controller.home.searchItem })
        XCTAssertFalse(window.toolbar!.items.contains { $0.itemIdentifier.rawValue == "navigation" })
        XCTAssertTrue(window.toolbar!.items.compactMap { $0 as? NSToolbarItemGroup }
            .flatMap(\.subitems).contains { $0.label == "Open comparison" && $0.isEnabled })
        let hiddenAction = NSMenuItem(title: "", action: NSSelectorFromString("markAndNext"), keyEquivalent: "")
        XCTAssertFalse(controller.validateMenuItem(hiddenAction))
        controller.perform(NSSelectorFromString("markAndNext"))
        XCTAssertEqual(controller.screen, .home)
    }

    @MainActor
    func testHomeResumeRetainsViewportScrollAndProtectsUnsavedComment() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Task.detached {
            _ = try ProcessRunner.run("/usr/bin/git", ["init", "-b", "main"], directory: directory.path)
            _ = try ProcessRunner.run("/usr/bin/git", ["-c", "user.name=Test", "-c", "user.email=test@example.com",
                "commit", "--allow-empty", "-m", "Initial"], directory: directory.path)
        }.value
        try (1...400).map { "let value\($0) = \($0)" }.joined(separator: "\n")
            .write(to: directory.appendingPathComponent("code.swift"), atomically: true, encoding: .utf8)
        let store = try ReviewStore(directory: directory.appendingPathComponent(".review"))
        let controller = ReviewWindowController(github: GitHubClient(clientID: "test", credentials: EmptyHomeCredentials()))
        controller.start(store: store, arguments: ["--repo", directory.path])
        await waitFor { controller.screen == .review }
        let window = try XCTUnwrap(controller.window)
        window.isReleasedWhenClosed = false
        defer { window.delegate = nil; controller.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        let viewport = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? DiffViewport }.first)
        viewport.scroll.contentView.scroll(to: NSPoint(x: 0, y: 750))
        viewport.scroll.reflectScrolledClipView(viewport.scroll.contentView)
        let before = viewport.scroll.contentView.bounds.origin
        let rows = viewport.table.numberOfRows
        controller.showHome()
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.screen, .home)
        XCTAssertFalse(controller.home.view.isHidden)
        controller.resumeReview()
        window.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.screen, .review)
        XCTAssertEqual(viewport.scroll.contentView.bounds.origin, before)
        XCTAssertEqual(viewport.table.numberOfRows, rows)
        XCTAssertTrue(controller.home.view.isHidden)
        XCTAssertNotNil(controller.home.resumeTitle)
        window.makeKeyAndOrderFront(nil)
        viewport.onComment?(LineSelection(file: 0, side: .new, start: 30, end: 30))
        let editor = try XCTUnwrap(NSApp.windows.flatMap { $0.contentView.map(descendants) ?? [] }
            .compactMap { $0 as? NSTextView }.first { $0.delegate is CommentEditorController })
        editor.string = "Unsaved review feedback"
        controller.showHome()
        XCTAssertEqual(controller.screen, .review)
        XCTAssertFalse(controller.settleDraft())
        controller.openPR("https://github.com/org/repo/pull/42")
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(editor.string, "Unsaved review feedback")
        editor.string = ""
        XCTAssertTrue(controller.settleDraft())
        controller.showHome()
        XCTAssertEqual(controller.screen, .home)
    }

    @MainActor
    func testCancelledExplicitPRDoesNotResumeOnLaterAccountBootstrapAndSignoutClearsRows() async throws {
        _ = NSApplication.shared
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HomeTransport.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let credentials = HomeCredentials()
        let client = GitHubClient(clientID: "test", session: session, credentials: credentials)
        let controller = ReviewWindowController(github: client)
        let window = try XCTUnwrap(controller.window)
        window.isReleasedWhenClosed = false
        defer { window.delegate = nil; controller.close() }
        controller.bootstrapAccount()
        await waitFor { window.toolbar?.items.contains { $0.label == "Sign in to GitHub" } == true }
        controller.openPR("https://github.com/org/repo/pull/42")
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertEqual(sheet.title, "Sign in to GitHub")
        let cancel = try XCTUnwrap(descendants(sheet.contentView!).compactMap { $0 as? NSButton }
            .first { $0.toolTip == "Cancel GitHub sign-in" })
        cancel.performClick(nil)
        await waitFor { window.attachedSheet == nil }
        try credentials.save(JSONEncoder().encode(GitHubCredential(accessToken: "fake-token", expiresAt: nil,
            refreshToken: nil, refreshExpiresAt: nil)))
        controller.bootstrapAccount()
        await waitFor { controller.home.results.count == 1 }
        XCTAssertNil(window.attachedSheet, "Cancelled intent must not open a checkout picker after later sign-in")
        XCTAssertEqual(controller.screen, .home)
        XCTAssertEqual(controller.home.results.first?.title, "Private draft")
        controller.perform(NSSelectorFromString("accountAction"))
        await waitFor { controller.home.results.isEmpty }
        XCTAssertTrue(controller.home.filteredResults.isEmpty)
        XCTAssertNil(try credentials.load())
        XCTAssertTrue(window.toolbar!.items.contains { $0.label == "Sign in to GitHub" })
    }

    @MainActor
    func testAccountResetDiscardsInflightHomeResults() async throws {
        _ = NSApplication.shared
        let loader = DeferredHomeLoader()
        let home = PRHomeController { _ in try await loader.load() }
        home.refresh()
        for _ in 0..<100 {
            if await loader.waiting { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        home.setUnavailable("Sign in to GitHub", clearResults: true)
        await loader.finish([PRSummary(pr: try GitHubPR.parse("https://github.com/org/repo/pull/1"),
            title: "Private PR", createdAt: Date(), isDraft: true)])
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(home.isLoading)
        XCTAssertTrue(home.results.isEmpty)
        XCTAssertTrue(home.filteredResults.isEmpty)
        XCTAssertEqual(home.table.numberOfRows, 0)
    }
}

private final class HomeCredentials: GitHubCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func load() throws -> Data? { lock.withLock { data } }
    func save(_ data: Data?) throws { lock.withLock { self.data = data } }
}

private final class HomeTransport: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: String
        switch request.url!.path {
        case "/user": body = #"{"login":"nek"}"#
        case "/search/issues":
            body = #"{"total_count":1,"incomplete_results":false,"items":[{"html_url":"https://github.com/org/repo/pull/42","title":"Private draft","created_at":"2026-09-20T10:00:00Z","draft":true,"pull_request":{"url":"https://api.github.com/repos/org/repo/pulls/42"}}]}"#
        case "/login/device/code":
            body = #"{"device_code":"fake-device","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#
        default:
            XCTFail("Unexpected network request: \(request.url!.path)")
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct EmptyHomeCredentials: GitHubCredentialStore {
    func load() throws -> Data? { nil }
    func save(_ data: Data?) throws {}
}

private actor DeferredHomeLoader {
    private var continuation: CheckedContinuation<[PRSummary], Error>?
    var waiting: Bool { continuation != nil }
    func load() async throws -> [PRSummary] {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ rows: [PRSummary]) {
        continuation?.resume(returning: rows)
        continuation = nil
    }
}
