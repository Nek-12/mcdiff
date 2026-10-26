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
    func testParentOutputOperationsCopyAndExportWithActionableFailures() async throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = "# Review\n\n## source.kt · new · 1\n\nPreserve this comment\n"
        try ReviewOutput.copy(text: text, pasteboard: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), text)
        pasteboard.clearContents()
        try ReviewOutput.copy(text: text, pasteboard: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), text)

        do {
            try await ReviewOutput.export(text: text, to: directory.appendingPathComponent("missing/review.md"))
            XCTFail("Exporting to a missing directory must fail")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        let exported = directory.appendingPathComponent("review.md")
        try await ReviewOutput.export(text: text, to: exported)
        XCTAssertEqual(try String(contentsOf: exported, encoding: .utf8), text)
    }

    @MainActor
    func testFinishDialogRendersBusyAndFailureStatesWithoutPerformingWork() throws {
        _ = NSApplication.shared
        var actions: [FinishReviewSheet.Action] = []
        let sheet = FinishReviewSheet { actions.append($0) }
        let content = try XCTUnwrap(sheet.window?.contentView)
        let buttons = descendants(content).compactMap { $0 as? NSButton }
        let labels = descendants(content).compactMap { $0 as? NSTextField }
        XCTAssertTrue(actions.isEmpty, "Presentation must not copy or archive")
        sheet.render(message: "Archiving review…", working: true)
        sheet.finish()
        sheet.reset()
        sheet.copyAgain()
        sheet.cancel()
        XCTAssertTrue(actions.isEmpty)
        XCTAssertTrue(buttons.allSatisfy { !$0.isEnabled })
        sheet.render(message: "Could not archive. Your active review is unchanged.", failed: true)
        XCTAssertTrue(buttons.allSatisfy(\.isEnabled))
        XCTAssertTrue(labels.contains { $0.stringValue.contains("Could not archive") && $0.textColor == .systemRed })
        sheet.copyAgain()
        sheet.reset()
        sheet.finish()
        sheet.cancel()
        XCTAssertEqual(actions, [.copy, .reset, .finish, .cancel])
        XCTAssertFalse(try XCTUnwrap(sheet.window).isVisible)
    }

    @MainActor
    func testResetClearsMarksButFinishPreservesThemWhenReopeningWhileCancelKeepsComments() async throws {
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
        try await waitFor { controller.isReviewReady }
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let cancelled = try XCTUnwrap(controller.prepareFinishReview(pasteboard: pasteboard))
        XCTAssertTrue(pasteboard.string(forType: .string)?.contains(comment.text) == true)
        XCTAssertNil(controller.prepareFinishReview(pasteboard: pasteboard), "Only one completion flow may be active")
        cancelled.cancel()
        XCTAssertEqual(controller.screen, .review)
        XCTAssertEqual(try store.loadProgress(identity: snapshot.identity).comments, [comment])

        let reset = try XCTUnwrap(controller.prepareFinishReview(pasteboard: pasteboard))
        let blocker = storage.appendingPathComponent("completed-reviews")
        try Data("blocking archive directory".utf8).write(to: blocker)
        reset.finish()
        let resetContent = try XCTUnwrap(reset.window?.contentView)
        let resetButtons = descendants(resetContent).compactMap { $0 as? NSButton }
        XCTAssertTrue(resetButtons.allSatisfy { !$0.isEnabled })
        reset.cancel()
        XCTAssertNil(controller.prepareFinishReview(pasteboard: pasteboard),
                     "An in-flight archive must settle before dismissal")
        try await waitFor {
            descendants(resetContent).compactMap { $0 as? NSTextField }.contains {
                $0.stringValue.contains("Could not archive")
            }
        }
        XCTAssertTrue(resetButtons.allSatisfy(\.isEnabled))
        XCTAssertEqual(controller.screen, .review)
        XCTAssertEqual(try store.loadProgress(identity: snapshot.identity).comments, [comment])
        XCTAssertEqual(try store.loadProgress(identity: snapshot.identity).reviewed, [file.path: file.fingerprint])
        try FileManager.default.removeItem(at: blocker)
        reset.reset()
        try await waitFor { controller.validateMenuItem(NSMenuItem(title: "", action: NSSelectorFromString("finishReview"), keyEquivalent: "")) }
        XCTAssertEqual(controller.screen, .review)
        XCTAssertNotNil(controller.home.resumeTitle)
        XCTAssertTrue(try store.loadProgress(identity: snapshot.identity).comments.isEmpty)
        XCTAssertTrue(try store.loadProgress(identity: snapshot.identity).reviewed.isEmpty)
        let resetView = try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? DiffViewport }.first)
        XCTAssertTrue(resetView.expanded.contains(file.path))
        XCTAssertFalse(resetView.isReviewed(file))

        resetView.onReviewToggle?(file, true)
        XCTAssertTrue(resetView.isReviewed(file))
        let finished = try XCTUnwrap(controller.prepareFinishReview(pasteboard: pasteboard))
        finished.finish()
        try await waitFor { controller.screen == .home }
        XCTAssertNil(controller.home.resumeTitle)
        XCTAssertTrue(try store.loadProgress(identity: snapshot.identity).comments.isEmpty)
        XCTAssertEqual(try store.loadProgress(identity: snapshot.identity).reviewed, [file.path: file.fingerprint])
        let archives = try FileManager.default.contentsOfDirectory(at: storage.appendingPathComponent("completed-reviews"),
                                                                  includingPropertiesForKeys: nil)
        XCTAssertEqual(archives.count, 2)
        let records = try archives.map { try JSONDecoder().decode(ReviewProgress.self, from:
            Data(contentsOf: $0.appendingPathComponent("progress.json"))) }
        let archived = try XCTUnwrap(records.first { !$0.comments.isEmpty })
        XCTAssertEqual(archived.comments, [comment])
        XCTAssertEqual(archived.reviewed, [file.path: file.fingerprint])
        controller.resumeReview()
        XCTAssertEqual(controller.screen, .home, "Finished rounds must not be resumable as active reviews")

        controller.start(store: store, arguments: ["--repo", directory.path])
        try await waitFor { controller.isReviewReady }
        let toolbar = try XCTUnwrap(window.toolbar)
        let actions = try XCTUnwrap(toolbar.items.compactMap { $0 as? NSToolbarItemGroup }.first {
            $0.subitems.first?.label == "Comments"
        })
        let comments = try XCTUnwrap(actions.subitems.first { $0.label == "Comments" })
        XCTAssertEqual(comments.badge, .count(0))
        let view = try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? DiffViewport }.first)
        XCTAssertFalse(view.expanded.contains(file.path))
        XCTAssertTrue(view.isReviewed(file))
        try Data("let value = 2\n".utf8).write(to: directory.appendingPathComponent("source.swift"))
        controller.start(store: store, arguments: ["--repo", directory.path])
        try await waitFor { controller.isReviewReady }
        let changed = try XCTUnwrap(view.files.first)
        XCTAssertNotEqual(changed.fingerprint, file.fingerprint)
        XCTAssertFalse(view.isReviewed(changed))
        XCTAssertTrue(view.expanded.contains(changed.path))
        XCTAssertEqual(try store.loadProgress(identity: snapshot.identity).reviewed, [file.path: file.fingerprint])
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(cancelled.window!.isVisible)
        XCTAssertFalse(finished.window!.isVisible)
    }
}

private struct FinishCredentials: GitHubCredentialStore {
    func load() throws -> Data? { nil }
    func save(_ data: Data?) throws {}
}
