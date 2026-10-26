import AppKit
import XCTest
@testable import McDiff
@testable import McDiffCore

final class ReviewDestinationTests: XCTestCase {
    @MainActor
    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Review destination did not settle")
    }

    private func review(_ name: String) -> PreparedReview {
        PreparedReview(snapshot: ReviewSnapshot(request: .init(repository: name, base: "main"),
                                                identity: name, title: name, baseRevision: "base",
                                                targetRevision: nil, files: []),
                       progress: ReviewProgress(), presentations: [:], markdown: [:])
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor
    func testLaterDestinationRejectsEarlierSuccessAndFailureEvenWhenWorkIgnoresCancellation() async throws {
        _ = NSApplication.shared
        let destination = ReviewDestinationController()
        let first = DestinationGate()
        let second = DestinationGate()
        var accepted: [String] = []
        destination.enter(.local(.init(repository: "first", base: "main")))
        destination.performLoad(message: "First", operation: { try await first.load() },
                         accept: { accepted.append($0.snapshot.title) }, recover: {})
        await first.waitUntilStarted()
        destination.enter(.local(.init(repository: "second", base: "main")))
        destination.performLoad(message: "Second", operation: { try await second.load() },
                         accept: { accepted.append($0.snapshot.title) }, recover: {})
        await second.waitUntilStarted()
        await first.finish(.success(review("first")))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(destination.phase, .loading)
        XCTAssertTrue(accepted.isEmpty)
        await second.finish(.success(review("second")))
        try await waitFor { destination.phase == .ready }
        XCTAssertEqual(accepted, ["second"])

        let staleFailure = DestinationGate()
        destination.enter(.local(.init(repository: "third", base: "main")))
        destination.performLoad(message: "Third", operation: { try await staleFailure.load() },
                         accept: { accepted.append($0.snapshot.title) }, recover: {})
        await staleFailure.waitUntilStarted()
        destination.cancel()
        await staleFailure.finish(.failure(GitError("Old failure")))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(destination.phase, .inactive)
        XCTAssertNil(destination.intent)
        XCTAssertEqual(accepted, ["second"])
    }

    @MainActor
    func testFailureLivesInDestinationWithRetryAndHome() async throws {
        _ = NSApplication.shared
        let destination = ReviewDestinationController()
        var retries = 0
        var homes = 0
        destination.onHome = { homes += 1 }
        destination.enter(.local(.init(repository: "missing", base: "main")))
        destination.performLoad(message: "Loading", operation: { throw GitError("The checkout was moved.") },
                         accept: { _ in XCTFail("Failed load must not install content") },
                         recover: { retries += 1 })
        XCTAssertEqual(destination.phase, .loading)
        try await waitFor { destination.phase == .failed }
        let labels = descendants(destination.view).compactMap { $0 as? NSTextField }
        XCTAssertTrue(labels.contains { $0.stringValue == "The checkout was moved." })
        let buttons = descendants(destination.view).compactMap { $0 as? NSButton }
        try XCTUnwrap(buttons.first { $0.title == "Retry" }).performClick(nil)
        try XCTUnwrap(buttons.first { $0.title == "Home" }).performClick(nil)
        XCTAssertEqual(retries, 1)
        XCTAssertEqual(homes, 1)
        XCTAssertNil(destination.view.window)
    }

    @MainActor
    func testLocalNavigationIsImmediateAndFailureRetriesWithoutAlert() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = ReviewWindowController(github: testGitHubClient())
        let window = try XCTUnwrap(controller.window)
        window.isReleasedWhenClosed = false
        defer { window.delegate = nil; controller.close() }
        controller.start(store: try ReviewStore(directory: directory.appendingPathComponent("store")), arguments: [])
        controller.load(.init(repository: directory.path, base: "main"))
        XCTAssertEqual(controller.screen, .review)
        XCTAssertEqual(controller.reviewDestination.phase, .loading)
        XCTAssertFalse(controller.isReviewReady)
        XCTAssertTrue(controller.home.view.isHidden)
        XCTAssertFalse(controller.reviewDestination.view.isHidden)
        XCTAssertFalse(window.isVisible)
        try await waitFor { controller.reviewDestination.phase == .failed }
        XCTAssertNil(window.attachedSheet)
        try await Task.detached {
            _ = try ProcessRunner.run("git", ["init", "-b", "main"], directory: directory.path)
            _ = try ProcessRunner.run("git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                                             "commit", "--allow-empty", "-m", "Initial"], directory: directory.path)
        }.value
        let retry = try XCTUnwrap(descendants(controller.reviewDestination.view).compactMap { $0 as? NSButton }
            .first { $0.title == "Retry" })
        retry.performClick(nil)
        XCTAssertEqual(controller.reviewDestination.phase, .loading)
        try await waitFor { controller.isReviewReady }
        XCTAssertFalse(controller.reviewDestination.view.isHidden)
        XCTAssertTrue(descendants(controller.reviewDestination.view).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue == "No changes in this comparison." })
        XCTAssertNil(window.attachedSheet)
    }

    @MainActor
    func testHomeCancelsLoadingAndResumeRetainsLoadedReview() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Task.detached {
            _ = try ProcessRunner.run("git", ["init", "-b", "main"], directory: directory.path)
            _ = try ProcessRunner.run("git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                                             "commit", "--allow-empty", "-m", "Initial"], directory: directory.path)
            try (1...400).map { "let value\($0) = \($0)" }.joined(separator: "\n")
                .write(to: directory.appendingPathComponent("code.swift"), atomically: true, encoding: .utf8)
        }.value
        let controller = ReviewWindowController(github: testGitHubClient())
        let window = try XCTUnwrap(controller.window)
        window.isReleasedWhenClosed = false
        defer { window.delegate = nil; controller.close() }
        controller.start(store: try ReviewStore(directory: directory.appendingPathComponent(".git/reviews")), arguments: [])
        controller.load(.init(repository: directory.path, base: "main"))
        try await waitFor { controller.isReviewReady }
        let viewport = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? DiffViewport }.first)
        let oldTitle = controller.home.resumeTitle
        let oldFiles = viewport.files.map(\.path)
        window.contentView?.layoutSubtreeIfNeeded()
        viewport.scroll.contentView.scroll(to: NSPoint(x: 0, y: 750))
        viewport.scroll.reflectScrolledClipView(viewport.scroll.contentView)
        let oldPosition = viewport.scroll.contentView.bounds.origin
        controller.load(.init(repository: directory.appendingPathComponent("missing").path, base: "main"))
        XCTAssertTrue(viewport.isHidden)
        XCTAssertFalse(controller.isReviewReady)
        controller.showHome()
        XCTAssertEqual(controller.screen, .home)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.screen, .home)
        XCTAssertEqual(controller.reviewDestination.phase, .inactive)
        XCTAssertEqual(controller.home.resumeTitle, oldTitle)
        controller.resumeReview()
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(controller.isReviewReady)
        XCTAssertFalse(viewport.isHidden)
        XCTAssertEqual(viewport.files.map(\.path), oldFiles)
        XCTAssertEqual(viewport.scroll.contentView.bounds.origin, oldPosition)
    }

    @MainActor
    func testPullRequestNavigatesBeforeAccountLookupAndShowsBootstrapFailureAndRetry() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = UnavailableDestinationCredentials()
        let controller = ReviewWindowController(github: GitHubClient(clientID: "test", credentials: credentials))
        let window = try XCTUnwrap(controller.window)
        window.isReleasedWhenClosed = false
        defer { window.delegate = nil; controller.close() }
        controller.start(store: try ReviewStore(directory: directory), arguments: [])
        controller.openPR("https://github.com/org/repo/pull/42")
        XCTAssertEqual(controller.screen, .review)
        XCTAssertEqual(controller.reviewDestination.intent,
                       .pullRequest(try GitHubPR.parse("https://github.com/org/repo/pull/42")))
        XCTAssertEqual(controller.reviewDestination.phase, .waiting)
        XCTAssertTrue(controller.home.view.isHidden)
        XCTAssertNil(window.attachedSheet)
        try await waitFor { controller.reviewDestination.phase == .failed }
        let labels = descendants(controller.reviewDestination.view).compactMap { $0 as? NSTextField }
        XCTAssertTrue(labels.contains { $0.stringValue.contains("Saved credentials are inaccessible") })
        let retry = try XCTUnwrap(descendants(controller.reviewDestination.view).compactMap { $0 as? NSButton }
            .first { $0.title == "Retry" })
        retry.performClick(nil)
        XCTAssertEqual(controller.reviewDestination.phase, .waiting)
        try await waitFor { controller.reviewDestination.phase == .failed && credentials.reads == 2 }
        controller.showHome()
        controller.bootstrapAccount()
        controller.openPR("https://github.com/org/repo/pull/43")
        controller.showHome()
        try await waitFor { credentials.reads == 3 }
        XCTAssertEqual(controller.screen, .home)
        XCTAssertEqual(controller.reviewDestination.phase, .inactive)
        XCTAssertNil(window.attachedSheet)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testPullRequestDestinationOwnsMetadataGitAndPresentationLoading() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let revisions = try await Task.detached {
            func git(_ arguments: [String]) throws -> String {
                try ProcessRunner.run("git", arguments, directory: directory.path).text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            _ = try git(["init", "-b", "main"])
            _ = try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "Initial"])
            let base = try git(["rev-parse", "HEAD"])
            try "let value = 1\n".write(to: directory.appendingPathComponent("source.swift"), atomically: true, encoding: .utf8)
            _ = try git(["add", "source.swift"])
            _ = try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "Change"])
            let head = try git(["rev-parse", "HEAD"])
            _ = try git(["remote", "add", "origin", "https://github.com/org/repo.git"])
            return (base, head)
        }.value
        DestinationGitHubProtocol.setResponse(
            Data(#"{"title":"Review changes","base":{"sha":"\#(revisions.0)"},"head":{"sha":"\#(revisions.1)"}}"#.utf8))
        defer { DestinationGitHubProtocol.setResponse(nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DestinationGitHubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = GitHubClient(clientID: "test", session: session,
                                  credentials: DestinationCredentials(token: true))
        let destination = ReviewDestinationController()
        let pr = try GitHubPR.parse("https://github.com/org/repo/pull/1")
        destination.enter(.pullRequest(pr))
        var accepted: PreparedReview?
        destination.load(store: try ReviewStore(directory: directory.appendingPathComponent(".git/reviews")),
                         github: client, checkout: directory.path, accept: { accepted = $0 })
        XCTAssertEqual(destination.phase, .loading)
        XCTAssertEqual(descendants(destination.view).compactMap { $0 as? NSTextField }
            .filter { !$0.isHidden }.map(\.stringValue), ["Loading review…"])
        try await waitFor { destination.phase == .ready || destination.phase == .failed }
        XCTAssertEqual(destination.phase, .ready)
        let result = try XCTUnwrap(accepted)
        XCTAssertEqual(result.snapshot.request.pullRequestURL, pr.url)
        XCTAssertEqual(result.snapshot.request.base, revisions.0)
        XCTAssertEqual(result.snapshot.request.target, revisions.1)
        XCTAssertEqual(result.snapshot.files.map(\.path), ["source.swift"])
        XCTAssertFalse(try XCTUnwrap(result.presentations["source.swift"]).isEmpty)
        let headAfter = try await Task.detached {
            try ProcessRunner.run("git", ["rev-parse", "HEAD"], directory: directory.path).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
        XCTAssertEqual(headAfter, revisions.1)
        XCTAssertNil(destination.view.window)
    }
}

private struct DestinationCredentials: GitHubCredentialStore {
    var token = false
    func load() throws -> Data? {
        token ? try JSONEncoder().encode(GitHubCredential(accessToken: "test", expiresAt: nil,
                                                        refreshToken: nil, refreshExpiresAt: nil)) : nil
    }
    func save(_ data: Data?) throws {}
}

private final class UnavailableDestinationCredentials: GitHubCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var reads: Int { lock.withLock { count } }
    func load() throws -> Data? {
        lock.withLock { count += 1 }
        throw GitHubError.credentials("Saved credentials are inaccessible")
    }
    func save(_ data: Data?) throws {}
}

private final class DestinationGitHubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var response: Data?
    static func setResponse(_ response: Data?) { lock.withLock { self.response = response } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let body = Self.lock.withLock({ Self.response }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                                                            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor DestinationGate {
    private var continuation: CheckedContinuation<PreparedReview, Error>?
    func load() async throws -> PreparedReview {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
        while continuation == nil { await Task.yield() }
    }
    func finish(_ result: Result<PreparedReview, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
