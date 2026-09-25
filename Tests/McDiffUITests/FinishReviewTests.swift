import AppKit
import XCTest
@testable import McDiff
@testable import McDiffCore

final class FinishReviewTests: XCTestCase {
    @MainActor
    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<600 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Review operation did not finish")
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor
    func testCopyExportCancelAndArchiveFailureKeepReviewAvailable() async throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = "# Review\n\n## source.kt · new · 1\n\nPreserve this comment\n"
        var attempts = 0
        var closed: Bool?
        let sheet = FinishReviewSheet(text: text, pasteboard: pasteboard, archive: {
            attempts += 1
            throw GitError("Storage is not writable")
        }, onClose: { closed = $0 })
        let window = try XCTUnwrap(sheet.window)
        let content = try XCTUnwrap(window.contentView)
        let labels = descendants(content).compactMap { $0 as? NSTextField }
        let buttons = descendants(content).compactMap { $0 as? NSButton }
        XCTAssertEqual(pasteboard.string(forType: .string), text)
        pasteboard.clearContents()
        sheet.copyAgain()
        XCTAssertEqual(pasteboard.string(forType: .string), text)

        sheet.export(to: directory.appendingPathComponent("missing/review.md"))
        try await waitFor { buttons.allSatisfy(\.isEnabled) }
        XCTAssertTrue(labels.contains { $0.stringValue.contains("Could not export") })
        let exported = directory.appendingPathComponent("review.md")
        sheet.export(to: exported)
        try await waitFor { buttons.allSatisfy(\.isEnabled) }
        XCTAssertEqual(try String(contentsOf: exported, encoding: .utf8), text)
        XCTAssertNil(closed)

        sheet.finish()
        XCTAssertTrue(buttons.allSatisfy { !$0.isEnabled })
        sheet.cancel()
        XCTAssertNil(closed, "An in-flight archive must settle before dismissal")
        try await waitFor { buttons.allSatisfy(\.isEnabled) }
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(labels.contains { $0.stringValue.contains("Storage is not writable") })
        XCTAssertNil(closed)
        sheet.copyAgain()
        XCTAssertEqual(pasteboard.string(forType: .string), text)
        sheet.cancel()
        XCTAssertEqual(closed, false)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testFinishArchivesAndReopeningComparisonStartsFreshWhileCancelKeepsIt() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try await Task.detached {
            _ = try ProcessRunner.run("git", ["init", "-b", "main"], directory: directory.path)
            _ = try ProcessRunner.run("git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                "commit", "--allow-empty", "-m", "Initial"], directory: directory.path)
            try Data("let value = 1\n".utf8).write(to: directory.appendingPathComponent("source.swift"))
            return try GitRepository(path: directory.path).load(ComparisonRequest(repository: directory.path, base: "main"))
        }.value
        let storage = directory.appendingPathComponent(".git/review")
        let store = try ReviewStore(directory: storage)
        let file = try XCTUnwrap(snapshot.files.first)
        let comment = ReviewComment(path: file.path, side: .new, startLine: 1, endLine: 1,
                                    text: "Review round one", fingerprint: file.fingerprint)
        try store.saveProgress(.init(reviewed: [file.path: file.fingerprint], comments: [comment]), identity: snapshot.identity)
        let controller = ReviewWindowController(github: GitHubClient(clientID: "test", credentials: FinishCredentials()))
        let window = try XCTUnwrap(controller.window)
        window.isReleasedWhenClosed = false
        defer { window.delegate = nil; controller.close() }
        controller.start(store: store, arguments: ["--repo", directory.path])
        try await waitFor { controller.screen == .review }
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let cancelled = try XCTUnwrap(controller.prepareFinishReview(pasteboard: pasteboard))
        XCTAssertTrue(pasteboard.string(forType: .string)?.contains(comment.text) == true)
        XCTAssertNil(controller.prepareFinishReview(pasteboard: pasteboard), "Only one completion flow may be active")
        cancelled.cancel()
        XCTAssertEqual(controller.screen, .review)
        XCTAssertEqual(try store.loadProgress(identity: snapshot.identity).comments, [comment])

        let finished = try XCTUnwrap(controller.prepareFinishReview(pasteboard: pasteboard))
        finished.finish()
        try await waitFor { controller.screen == .home }
        XCTAssertNil(controller.home.resumeTitle)
        XCTAssertTrue(try store.loadProgress(identity: snapshot.identity).comments.isEmpty)
        XCTAssertTrue(try store.loadProgress(identity: snapshot.identity).reviewed.isEmpty)
        let archives = try FileManager.default.contentsOfDirectory(at: storage.appendingPathComponent("completed-reviews"),
                                                                  includingPropertiesForKeys: nil)
        let archived = try JSONDecoder().decode(ReviewProgress.self, from: Data(contentsOf: XCTUnwrap(archives.first)
            .appendingPathComponent("progress.json")))
        XCTAssertEqual(archived.comments, [comment])
        XCTAssertEqual(archived.reviewed, [file.path: file.fingerprint])
        controller.resumeReview()
        XCTAssertEqual(controller.screen, .home, "Finished rounds must not be resumable as active reviews")

        controller.start(store: store, arguments: ["--repo", directory.path])
        try await waitFor { controller.screen == .review }
        let toolbar = try XCTUnwrap(window.toolbar)
        let comments = try XCTUnwrap(toolbar.items.first { $0.label == "Comments" })
        XCTAssertEqual(comments.badge, .count(0))
        let view = try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? DiffViewport }.first)
        XCTAssertTrue(view.expanded.contains(file.path))
        XCTAssertFalse(view.isReviewed(file))
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(cancelled.window!.isVisible)
        XCTAssertFalse(finished.window!.isVisible)
    }
}

private struct FinishCredentials: GitHubCredentialStore {
    func load() throws -> Data? { nil }
    func save(_ data: Data?) throws {}
}
