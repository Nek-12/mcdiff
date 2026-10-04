import AppKit
@testable import McDiffCore
import XCTest
@testable import McDiff

final class ToolbarInteractionTests: XCTestCase {
    @MainActor
    func testSearchIdentifiesPRAndLocalComparison() {
        func snapshot(_ request: ComparisonRequest) -> ReviewSnapshot {
            ReviewSnapshot(request: request, identity: "review", title: "comparison",
                           baseRevision: "base", targetRevision: nil, files: [])
        }
        XCTAssertEqual(ReviewWindowController.searchPlaceholder(for: snapshot(.init(
            repository: "/repo", base: "main", pullRequestURL: "https://github.com/owner/repo/pull/42",
            pullRequestTitle: "Fix a very long title"))), "Search PR #42 Fix a very long title")
        XCTAssertEqual(ReviewWindowController.searchPlaceholder(for: snapshot(.init(
            repository: "/checkout/app", base: "main"))), "Search app: main → Working tree")
        XCTAssertEqual(ReviewWindowController.searchPlaceholder(for: snapshot(.init(
            repository: "/checkout/app", base: String(repeating: "a", count: 40), target: "feature"))),
                       "Search app: aaaaaaaa → feature")
    }

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
            if count == 2, let chrome = window.contentView?.superview {
                let separator = try XCTUnwrap(toolbar.items.compactMap { $0 as? NSTrackingSeparatorToolbarItem }.first)
                let split = separator.splitView
                for width in [CGFloat(300), 350, 280] {
                    split.setPosition(width, ofDividerAt: separator.dividerIndex)
                    chrome.layoutSubtreeIfNeeded()
                    let refresh = try XCTUnwrap(descendants(of: chrome).first { $0.toolTip == "Refresh comparison (⌘R)" })
                    let home = try XCTUnwrap(descendants(of: chrome).first { $0.toolTip == "Home" })
                    let sidebar = split.subviews[separator.dividerIndex]
                    let edge = chrome.convert(sidebar.bounds, from: sidebar).maxX
                    let refreshFrame = chrome.convert(refresh.bounds, from: refresh)
                    let homeFrame = chrome.convert(home.bounds, from: home)
                    XCTAssertEqual(refreshFrame.maxX, edge, accuracy: 12, "Sidebar actions must follow the divider")
                    XCTAssertEqual(homeFrame.maxX, refreshFrame.minX, accuracy: 1)
                }
            }
            let finish = try XCTUnwrap(toolbar.items.last)
            XCTAssertEqual(finish.label, "Finish review")
            XCTAssertEqual(finish.style, .prominent)
            let navigation = try XCTUnwrap(toolbar.items.compactMap { $0 as? NSToolbarItemGroup }.first {
                $0.subitems.first?.label == "Comments"
            })
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
    func testWrapStateRemainsNeutralAndPersistsAcrossControllers() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReviewStore(directory: directory)
        let controller = ReviewWindowController(github: GitHubClient(clientID: "test", credentials: ToolbarCredentials()))
        controller.start(store: store, arguments: [])
        let toolbar = try XCTUnwrap(controller.window?.toolbar)
        let wrap = try XCTUnwrap(controller.toolbar(toolbar, itemForItemIdentifier: .init("wrap"), willBeInsertedIntoToolbar: false))
        let view = try XCTUnwrap(descendants(of: try XCTUnwrap(controller.window?.contentView)).compactMap { $0 as? DiffViewport }.first)
        for enabled in [true, false, true] {
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(wrap.action), to: wrap.target, from: wrap))
            XCTAssertEqual(view.softWrap, enabled)
            XCTAssertEqual(wrap.title, enabled ? "Wrap on" : "Wrap off")
            XCTAssertEqual(wrap.style, .plain)
            XCTAssertEqual(wrap.image?.isTemplate, !enabled, "Only the on icon carries the accent palette")
            XCTAssertEqual(try store.loadPreferences().softWrap, enabled)
        }
        let reopened = ReviewWindowController(github: GitHubClient(clientID: "test", credentials: ToolbarCredentials()))
        reopened.start(store: store, arguments: [])
        let reopenedToolbar = try XCTUnwrap(reopened.window?.toolbar)
        let restored = try XCTUnwrap(reopened.toolbar(reopenedToolbar, itemForItemIdentifier: .init("wrap"), willBeInsertedIntoToolbar: false))
        XCTAssertEqual(restored.title, "Wrap on")
        XCTAssertEqual(restored.style, .plain)
        XCTAssertFalse(controller.window!.isVisible)
        XCTAssertFalse(reopened.window!.isVisible)
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
        XCTAssertEqual(toggle.style, .plain)
        XCTAssertEqual(toggle.toolTip, "Switch to split diff")
        XCTAssertTrue(NSApp.sendAction(action, to: toggle.target, from: toggle))
        XCTAssertEqual(viewport.diffLayout, .split)
        XCTAssertEqual(toggle.title, "Unified")
        XCTAssertEqual(toggle.style, .plain)
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
