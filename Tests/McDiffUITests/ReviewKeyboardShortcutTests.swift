import AppKit
import XCTest
@testable import McDiff
@testable import McDiffCore

final class ReviewKeyboardShortcutTests: XCTestCase {
    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func key(_ characters: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false,
                                      keyCode: characters == " " ? 49 : 36))
    }

    @MainActor
    func testSidebarReviewKeysAdvanceWithoutUnreviewingAndPreserveEditorsAndFailedSaves() async throws {
        try await exerciseReviewKeys(inDiff: false)
    }

    @MainActor
    func testDiffReviewKeysAdvanceWithoutUnreviewingAndPreserveEditorsAndFailedSaves() async throws {
        try await exerciseReviewKeys(inDiff: true)
    }

    @MainActor
    private func exerciseReviewKeys(inDiff: Bool) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Task.detached {
            _ = try ProcessRunner.run("/usr/bin/git", ["init", "-b", "main"], directory: directory.path)
            _ = try ProcessRunner.run("/usr/bin/git", ["-c", "user.name=Test", "-c", "user.email=test@example.com",
                                                     "commit", "--allow-empty", "-m", "Initial"], directory: directory.path)
            for name in ["a.swift", "b.swift", "c.swift", "README.md"] {
                try "let value = 1\n".write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        }.value
        let storage = directory.appendingPathComponent(".git/reviews")
        let store = try ReviewStore(directory: storage)
        let controller = ReviewWindowController(github: testGitHubClient())
        controller.start(store: store, arguments: ["--repo", directory.path])
        let window = try XCTUnwrap(controller.window)
        defer { window.delegate = nil; controller.close() }
        for _ in 0..<400 {
            if controller.isReviewReady { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(controller.isReviewReady)
        let finishMenuItem = NSMenuItem(title: "Finish review…", action: #selector(ReviewWindowController.finishReview),
                                       keyEquivalent: "\r")
        finishMenuItem.target = controller
        finishMenuItem.keyEquivalentModifierMask = .control
        let finishMenu = NSMenu(title: "Review")
        finishMenu.addItem(finishMenuItem)
        finishMenu.update()
        XCTAssertTrue(finishMenuItem.isEnabled)
        XCTAssertTrue(controller.validateMenuItem(finishMenuItem))
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let views = descendants(content)
        let viewport = try XCTUnwrap(views.compactMap { $0 as? DiffViewport }.first)
        let sidebar = try XCTUnwrap(views.compactMap { $0 as? NSTableView }
            .first { $0.tableColumns.first?.identifier.rawValue == "path" })
        let keyboardTarget = inDiff ? viewport.table : sidebar
        let file = try XCTUnwrap(viewport.files.first { $0.path == "b.swift" })
        let first = try XCTUnwrap(viewport.files.first { $0.path == "a.swift" })
        let third = try XCTUnwrap(viewport.files.first { $0.path == "c.swift" })
        viewport.onReviewToggle?(third, true)
        let snapshot = try await Task.detached {
            try GitRepository(path: directory.path).load(ComparisonRequest(repository: directory.path, base: "main"))
        }.value

        // Sidebar selection deliberately leaves the viewport on another file.
        if inDiff { viewport.navigate(to: 1) }
        else { sidebar.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false) }
        keyboardTarget.keyDown(with: try key(" "))
        XCTAssertTrue(viewport.isReviewed(file))
        XCTAssertFalse(viewport.isReviewed(first))
        XCTAssertFalse(viewport.expanded.contains(file.path))
        XCTAssertEqual(try store.loadProgress(identity: snapshot.identity).reviewed[file.path], file.fingerprint)
        XCTAssertEqual(sidebar.selectedRow, 0, "Advance must skip manually and automatically reviewed files and wrap")

        // A rejected save must not change either the mark or the expansion.
        let savedProgress = try store.loadProgress(identity: snapshot.identity)
        let expansionBeforeFailure = viewport.expanded
        try FileManager.default.removeItem(at: storage)
        try Data("not a directory".utf8).write(to: storage)
        controller.window = nil
        keyboardTarget.keyDown(with: try key(" "))
        controller.window = window
        XCTAssertTrue(viewport.isReviewed(file))
        XCTAssertFalse(viewport.isReviewed(first))
        XCTAssertEqual(viewport.expanded, expansionBeforeFailure)
        XCTAssertEqual(sidebar.selectedRow, 0)
        // Already-reviewed files advance even when storage is unavailable: there is nothing to save.
        if inDiff { viewport.navigate(to: 1) }
        else { sidebar.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false) }
        controller.window = nil
        keyboardTarget.keyDown(with: try key("\u{3}"))
        controller.window = window
        XCTAssertEqual(sidebar.selectedRow, 0)
        XCTAssertTrue(viewport.isReviewed(file))
        XCTAssertFalse(viewport.isReviewed(first))
        try FileManager.default.removeItem(at: storage)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try store.saveProgress(savedProgress, identity: snapshot.identity)

        let documentation = try XCTUnwrap(viewport.files.first { $0.path == "README.md" })
        if inDiff { viewport.navigate(to: 3) }
        else { sidebar.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false) }
        XCTAssertTrue(viewport.isReviewed(documentation))
        keyboardTarget.keyDown(with: try key("\r"))
        XCTAssertTrue(viewport.isReviewed(documentation))
        XCTAssertNil(try store.loadProgress(identity: snapshot.identity).reviewed[documentation.path])
        XCTAssertEqual(sidebar.selectedRow, 0, "An automatically reviewed current file must still advance")

        let search = try XCTUnwrap(window.toolbar?.items.compactMap { $0 as? NSSearchToolbarItem }
            .first { $0.itemIdentifier.rawValue == "search" }?.searchField)
        XCTAssertTrue(window.makeFirstResponder(search))
        let editor = try XCTUnwrap(search.currentEditor() as? NSTextView)
        XCTAssertFalse(controller.validateMenuItem(finishMenuItem),
                       "Control-Return must stay with the search editor")
        editor.keyDown(with: try key(" "))
        XCTAssertEqual(editor.string, " ", "Space in search must remain text input")
        editor.keyDown(with: try key("\r"))
        XCTAssertTrue(viewport.isReviewed(file), "Return in search must not toggle the review mark")
        XCTAssertFalse(viewport.isReviewed(first))

        let comment = ReviewComment(path: file.path, side: .new, startLine: 1, endLine: 1,
                                    text: "", fingerprint: file.fingerprint)
        var savedComment = false
        let commentEditor = CommentEditorController(comment: comment, isNew: true, onSave: { _ in savedComment = true })
        let commentInput = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        commentInput.delegate = commentEditor
        content.addSubview(commentInput)
        XCTAssertTrue(window.makeFirstResponder(commentInput))
        commentInput.keyDown(with: try key(" "))
        commentInput.keyDown(with: try key("\r"))
        XCTAssertEqual(commentInput.string, " \n")
        XCTAssertFalse(controller.validateMenuItem(finishMenuItem),
                       "Control-Return must not finish a review while editing a comment")
        finishMenu.update()
        XCTAssertFalse(finishMenuItem.isEnabled, "Native menu routing must disable the shortcut during editing")
        commentInput.keyDown(with: try key("\r", modifiers: .control))
        XCTAssertFalse(savedComment)
        XCTAssertTrue(viewport.isReviewed(file))
        XCTAssertFalse(viewport.isReviewed(first))
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(window.makeFirstResponder(sidebar))
        XCTAssertTrue(controller.validateMenuItem(finishMenuItem))
        finishMenu.update()
        XCTAssertTrue(finishMenuItem.isEnabled)

        // The diff uses the same action; repeated presses at the end never unreview or open Finish.
        viewport.table.keyDown(with: try key(" "))
        XCTAssertTrue(viewport.isReviewed(first))
        XCTAssertEqual(sidebar.selectedRow, 0)
        let completed = try store.loadProgress(identity: snapshot.identity)
        for characters in [" ", "\r", "\u{3}"] {
            sidebar.keyDown(with: try key(characters))
            viewport.table.keyDown(with: try key(characters))
            XCTAssertTrue(viewport.files.allSatisfy(viewport.isReviewed))
            XCTAssertEqual(sidebar.selectedRow, 0)
            XCTAssertNil(window.attachedSheet)
        }
        XCTAssertEqual(try store.loadProgress(identity: snapshot.identity).reviewed, completed.reviewed)
        viewport.onReviewToggle?(first, false)
        XCTAssertFalse(viewport.isReviewed(first), "Explicit checkboxes must still support unreviewing")
        XCTAssertTrue(viewport.expanded.contains(first.path))
        XCTAssertNil(try store.loadProgress(identity: snapshot.identity).reviewed[first.path])
        XCTAssertFalse(window.isVisible, "Keyboard tests must keep the window offscreen")
    }

    @MainActor
    func testFinishMenuUsesControlReturnAndDoesNotBindBareReturn() throws {
        _ = NSApplication.shared
        let previousMenu = NSApp.mainMenu
        NSApp.mainMenu = NSMenu()
        defer { NSApp.mainMenu = previousMenu }
        let controller = ReviewWindowController(github: testGitHubClient())
        defer { controller.window?.delegate = nil; controller.close() }
        let menu = try XCTUnwrap(NSApp.mainMenu?.items.last { $0.submenu?.title == "Review" }?.submenu)
        let finish = try XCTUnwrap(menu.items.first { $0.title == "Finish review…" })
        XCTAssertEqual(finish.keyEquivalent, "\r")
        XCTAssertEqual(finish.keyEquivalentModifierMask, .control)
        XCTAssertTrue(finish.target === controller)
        XCTAssertEqual(finish.action, #selector(ReviewWindowController.finishReview))
        XCTAssertFalse(controller.validateMenuItem(finish), "Home must not offer finishing a review")
        XCTAssertFalse(menu.items.contains { $0.keyEquivalent == "\r" && $0.keyEquivalentModifierMask.isEmpty })
    }
}
