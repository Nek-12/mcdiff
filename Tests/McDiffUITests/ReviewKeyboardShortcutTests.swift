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
    func testSidebarKeysToggleSelectedFilePersistAndLeaveAutomaticReviewUntouched() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Task.detached {
            _ = try ProcessRunner.run("/usr/bin/git", ["init", "-b", "main"], directory: directory.path)
            _ = try ProcessRunner.run("/usr/bin/git", ["-c", "user.name=Test", "-c", "user.email=test@example.com",
                                                     "commit", "--allow-empty", "-m", "Initial"], directory: directory.path)
            for name in ["a.swift", "b.swift", "README.md"] {
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
        let file = try XCTUnwrap(viewport.files.first { $0.path == "b.swift" })
        let first = try XCTUnwrap(viewport.files.first { $0.path == "a.swift" })
        let snapshot = try await Task.detached {
            try GitRepository(path: directory.path).load(ComparisonRequest(repository: directory.path, base: "main"))
        }.value

        // Programmatic selection deliberately leaves the viewport on another file.
        sidebar.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        sidebar.keyDown(with: try key(" "))
        XCTAssertTrue(viewport.isReviewed(file))
        XCTAssertFalse(viewport.isReviewed(first))
        XCTAssertFalse(viewport.expanded.contains(file.path))
        XCTAssertEqual(try store.loadProgress(identity: snapshot.identity).reviewed[file.path], file.fingerprint)

        sidebar.keyDown(with: try key("\r"))
        XCTAssertFalse(viewport.isReviewed(file))
        XCTAssertTrue(viewport.expanded.contains(file.path))
        XCTAssertNil(try store.loadProgress(identity: snapshot.identity).reviewed[file.path])
        sidebar.keyDown(with: try key("\u{3}"))
        XCTAssertTrue(viewport.isReviewed(file))

        // A rejected save must not change either the mark or the expansion.
        let savedProgress = try store.loadProgress(identity: snapshot.identity)
        try FileManager.default.removeItem(at: storage)
        try Data("not a directory".utf8).write(to: storage)
        controller.window = nil
        sidebar.keyDown(with: try key(" "))
        controller.window = window
        XCTAssertTrue(viewport.isReviewed(file))
        XCTAssertFalse(viewport.expanded.contains(file.path))
        try FileManager.default.removeItem(at: storage)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try store.saveProgress(savedProgress, identity: snapshot.identity)

        let documentation = try XCTUnwrap(viewport.files.first { $0.path == "README.md" })
        sidebar.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        XCTAssertTrue(viewport.isReviewed(documentation))
        let expansion = viewport.expanded
        sidebar.keyDown(with: try key("\r"))
        XCTAssertTrue(viewport.isReviewed(documentation))
        XCTAssertEqual(viewport.expanded, expansion)

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
