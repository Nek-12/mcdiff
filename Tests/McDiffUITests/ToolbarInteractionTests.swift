import AppKit
@testable import McDiffCore
import XCTest
@testable import McDiff

final class ToolbarInteractionTests: XCTestCase {
    @MainActor
    func testReviewToolbarCountsSavedCommentsAndKeepsReviewActionAtTrailingEdge() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try await Task.detached {
            _ = try ProcessRunner.run("git", ["init", "-b", "main"], directory: directory.path)
            _ = try ProcessRunner.run("git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                "commit", "--allow-empty", "-m", "Initial"], directory: directory.path)
            try Data("let value = 1\n".utf8).write(to: directory.appendingPathComponent("main.swift"))
            return try GitRepository(path: directory.path).load(ComparisonRequest(repository: directory.path, base: "main"))
        }.value
        let store = try ReviewStore(directory: directory.appendingPathComponent(".git/review"))
        let file = try XCTUnwrap(snapshot.files.first)
        let comments = [
            ReviewComment(path: file.path, side: .new, startLine: 1, endLine: 1,
                          text: "Current comment", fingerprint: file.fingerprint),
            ReviewComment(path: "removed.swift", side: .old, startLine: 2, endLine: 4,
                          text: "Stale comment", fingerprint: "old")
        ]
        let controller = ReviewWindowController(github: GitHubClient(clientID: "test", credentials: ToolbarCredentials()))
        let window = try XCTUnwrap(controller.window)
        window.isReleasedWhenClosed = false
        defer { window.delegate = nil; controller.close() }
        let toolbar = try XCTUnwrap(window.toolbar)
        for count in [2, 0, 1] {
            try store.saveProgress(ReviewProgress(comments: Array(comments.prefix(count))), identity: snapshot.identity)
            if controller.screen == .review { controller.showHome() }
            controller.start(store: store, arguments: ["--repo", directory.path])
            for _ in 0..<400 {
                if controller.screen == .review { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(controller.screen, .review)
            let navigation = try XCTUnwrap(toolbar.items.last as? NSToolbarItemGroup)
            XCTAssertEqual(navigation.subitems.map(\.label), ["Comments", "Next file", "Previous file", "Review & next"])
            XCTAssertFalse(toolbar.items.contains { $0.label == "Comments" })
            let commentItem = try XCTUnwrap(navigation.subitems.first)
            XCTAssertEqual(commentItem.badge, .count(count))
            XCTAssertEqual(commentItem.isEnabled, count > 0)
            XCTAssertEqual(commentItem.toolTip, "\(count) comments")
            XCTAssertEqual(navigation.subitems.last?.label, "Review & next")
            let markReviewed = try XCTUnwrap(navigation.subitems.last)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(markReviewed.action), to: markReviewed.target, from: markReviewed))
            XCTAssertEqual(try store.loadProgress(identity: snapshot.identity).reviewed[file.path], file.fingerprint)
            let searchIndex = try XCTUnwrap(toolbar.items.firstIndex { $0 is NSSearchToolbarItem })
            let commentIndex = try XCTUnwrap(toolbar.items.firstIndex { $0 === navigation })
            XCTAssertLessThan(searchIndex, commentIndex)
            XCTAssertFalse(window.isVisible)
        }
    }

    @MainActor
    func testLayoutToggleShowsDestinationAndUpdatesViewport() throws {
        _ = NSApplication.shared
        let controller = ReviewWindowController()
        let window = try XCTUnwrap(controller.window)
        let toolbar = try XCTUnwrap(window.toolbar)
        let items = controller.toolbarAllowedItemIdentifiers(toolbar).compactMap {
            controller.toolbar(toolbar, itemForItemIdentifier: $0, willBeInsertedIntoToolbar: false)
        }
        let toggle = try XCTUnwrap(items.first { $0.title == "Unified" })
        let viewport = try XCTUnwrap(descendants(of: try XCTUnwrap(window.contentView)).compactMap { $0 as? DiffViewport }.first)
        let action = try XCTUnwrap(toggle.action)
        XCTAssertEqual(viewport.diffLayout, .split)
        XCTAssertTrue(NSApp.sendAction(action, to: toggle.target, from: toggle))
        XCTAssertEqual(viewport.diffLayout, .unified)
        XCTAssertEqual(toggle.title, "Split")
        XCTAssertEqual(toggle.toolTip, "Switch to split diff")
        XCTAssertTrue(NSApp.sendAction(action, to: toggle.target, from: toggle))
        XCTAssertEqual(viewport.diffLayout, .split)
        XCTAssertEqual(toggle.title, "Unified")
        XCTAssertEqual(toggle.toolTip, "Switch to unified diff")
    }

    @MainActor
    func testToolbarActionsHaveReadableTooltips() throws {
        _ = NSApplication.shared
        let controller = ReviewWindowController()
        let toolbar = try XCTUnwrap(controller.window?.toolbar)
        for identifier in controller.toolbarAllowedItemIdentifiers(toolbar) {
            guard let item = controller.toolbar(toolbar, itemForItemIdentifier: identifier,
                                                willBeInsertedIntoToolbar: false) else { continue }
            let actions = (item as? NSToolbarItemGroup)?.subitems ?? [item]
            for action in actions where action.action != nil {
                XCTAssertFalse(action.toolTip?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
                               "Missing tooltip for \(action.label)")
            }
        }
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}

private struct ToolbarCredentials: GitHubCredentialStore {
    func load() throws -> Data? { nil }
    func save(_ data: Data?) throws {}
}
