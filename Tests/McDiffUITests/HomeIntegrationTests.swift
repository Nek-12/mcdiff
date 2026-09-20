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
    func testHomeResumeRetainsViewportScroll() async throws {
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
    }

    @MainActor
    func testAccountResetDiscardsInflightHomeResults() async throws {
        _ = NSApplication.shared
        let loader = DeferredHomeLoader()
        let home = PRHomeController { _, _ in try await loader.load() }
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
        XCTAssertEqual(home.table.numberOfRows, 0)
    }

    @MainActor
    func testWindowPRPasteUsesTheCanonicalURLParserWithoutTouchingTheRealClipboard() throws {
        let pasteboard = try XCTUnwrap(NSPasteboard.withUniqueName())
        defer { pasteboard.releaseGlobally() }
        let drop = PRDropView(frame: .zero, pasteboard: pasteboard)
        var opened: [String] = []
        drop.onPaste = { opened.append($0) }
        let menuItem = NSMenuItem(title: "Paste", action: #selector(PRDropView.paste(_:)), keyEquivalent: "v")

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("https://github.com/owner/repo/pull/42", forType: .string))
        XCTAssertTrue(drop.validateMenuItem(menuItem))
        drop.paste(nil)
        XCTAssertEqual(opened, ["https://github.com/owner/repo/pull/42"])

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("https://example.com/not-a-pull-request", forType: .string))
        XCTAssertFalse(drop.validateMenuItem(menuItem))
        drop.paste(nil)
        XCTAssertEqual(opened, ["https://github.com/owner/repo/pull/42"])
    }
}

private struct EmptyHomeCredentials: GitHubCredentialStore {
    func load() throws -> Data? { nil }
    func save(_ data: Data?) throws {}
}

private actor DeferredHomeLoader {
    private var continuation: CheckedContinuation<PRPage, Error>?
    var waiting: Bool { continuation != nil }
    func load() async throws -> PRPage {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ rows: [PRSummary]) {
        continuation?.resume(returning: PRPage(items: rows, hasNext: false))
        continuation = nil
    }
}
