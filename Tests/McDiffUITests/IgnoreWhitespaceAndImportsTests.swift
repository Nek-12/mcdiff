import AppKit
import XCTest
@testable import McDiff
@testable import McDiffCore

final class IgnoreWhitespaceAndImportsTests: XCTestCase {
    @MainActor
    func testEveryIncludeSwitchControlsAutomaticReviewAndPreservesManualProgress() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try await Task.detached {
            func git(_ args: [String]) throws {
                _ = try ProcessRunner.run("git", args, directory: directory.path)
            }
            func write(_ path: String, _ text: String) throws {
                let url = directory.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            try git(["init", "-b", "main"])
            try write("removed.swift", "let removed = true\n")
            try write("manual.swift", "let value = 1\n")
            try write("format.go", "package example\nvar value = 1\n")
            try git(["add", "."])
            try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "Baseline"])
            try FileManager.default.removeItem(at: directory.appendingPathComponent("removed.swift"))
            try write("manual.swift", "let value = 2\n")
            try write("format.go", "package example\nvar value    = 1\n")
            try write("Tests/ExampleTests.swift", "let test = true\n")
            try write("guide.md", "# Documentation\n")
            try write("generated/Model.swift", "let generated = true\n")
            return try GitRepository(path: directory.path).load(.init(repository: directory.path, base: "main"))
        }.value
        let store = try ReviewStore(directory: directory.appendingPathComponent(".git/review"))
        let manual = try XCTUnwrap(snapshot.files.first { $0.path == "manual.swift" })
        let removed = try XCTUnwrap(snapshot.files.first { $0.path == "removed.swift" })
        let comment = ReviewComment(path: removed.path, side: .old, startLine: 1, endLine: 1,
                                    text: "Keep deletion context", fingerprint: removed.fingerprint)
        let progress = ReviewProgress(reviewed: [manual.path: manual.fingerprint], comments: [comment])
        try store.saveProgress(progress, identity: snapshot.identity)
        let controller = ReviewWindowController(github: testGitHubClient())
        controller.start(store: store, arguments: ["--repo", directory.path])
        try await waitForReview(controller)
        let window = try XCTUnwrap(controller.window)
        window.isReleasedWhenClosed = false
        defer { window.delegate = nil; controller.close() }
        let content = try XCTUnwrap(window.contentView)
        let view = try XCTUnwrap(descendants(content).compactMap { $0 as? DiffViewport }.first)
        let buttons = descendants(content).compactMap { $0 as? NSButton }
        let manualIndex = try XCTUnwrap(view.files.firstIndex { $0.path == manual.path })
        view.setExpanded(true, file: manualIndex)
        for (title, path, initiallyIncluded) in [
            ("Tests", "Tests/ExampleTests.swift", false),
            ("Documentation and non-code", "guide.md", false),
            ("Generated and noise", "generated/Model.swift", false),
            ("Whitespace and imports", "format.go", true),
            ("Meta changes", "removed.swift", false)
        ] {
            let button = try XCTUnwrap(buttons.first { $0.title == title })
            let file = try XCTUnwrap(view.files.first { $0.path == path })
            XCTAssertEqual(button.state == .on, initiallyIncluded, title)
            for included in [!initiallyIncluded, initiallyIncluded] {
                let untouched = view.expanded.subtracting([path])
                button.performClick(nil)
                XCTAssertEqual(button.state == .on, included, title)
                XCTAssertEqual(view.isReviewed(file), !included, title)
                XCTAssertEqual(view.expanded.contains(path), included, title)
                XCTAssertEqual(view.expanded.subtracting([path]), untouched, title)
                let row = try XCTUnwrap(view.rows.firstIndex {
                    guard view.files[$0.file].path == path, case .file = $0.content else { return false }
                    return true
                })
                let header = DiffCell(frame: NSRect(x: 0, y: 0, width: 800, height: 38))
                header.owner = view
                header.rowIndex = row
                header.updateHeaderButton()
                let reviewed = try XCTUnwrap(header.subviews.compactMap { $0 as? AnimatedCheckbox }.first)
                XCTAssertEqual(reviewed.isEnabled, included, title)
                XCTAssertEqual(reviewed.state == .on, !included, title)
                XCTAssertTrue(view.isReviewed(manual))
                XCTAssertTrue(view.expanded.contains(manual.path))
                let persisted = try store.loadProgress(identity: snapshot.identity)
                XCTAssertEqual(persisted.reviewed, progress.reviewed)
                XCTAssertEqual(persisted.comments, [comment])
            }
        }
        let saved = try store.loadPreferences().filters
        XCTAssertTrue(saved.tests)
        XCTAssertTrue(saved.documentation)
        XCTAssertTrue(saved.generated)
        XCTAssertFalse(saved.whitespaceAndImports)
        XCTAssertTrue(saved.metaChanges)
        XCTAssertFalse(window.isVisible)
        XCTAssertNil(window.attachedSheet)
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor
    private func waitForReview(_ controller: ReviewWindowController) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !controller.isReviewReady {
            guard ContinuousClock.now < deadline else { throw GitError("Review did not load") }
            try await Task.sleep(for: .milliseconds(10))
        }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
    }

    @MainActor
    func testFourthSwitchPersistsAndUpdatesChecksExpansionAndFooterWithoutWritingManualProgress() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try await Task.detached {
            func git(_ args: [String]) throws {
                _ = try ProcessRunner.run("git", args, directory: directory.path)
            }
            func write(_ path: String, _ text: String) throws {
                try text.write(to: directory.appendingPathComponent(path), atomically: true, encoding: .utf8)
            }
            try git(["init", "-b", "main"])
            try write("format.go", "package example\nimport \"fmt\"\nvar value = 1\n")
            try write("literal.go", "package example\nvar text = \"two words\"\n")
            try write("logic.go", "package example\nvar value = 1\nvar stable = true\n")
            try git(["add", "."])
            try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "Baseline"])
            try write("format.go", "package renamed\nimport \"os\"\nvar value    = 1\n")
            try write("literal.go", "package example\nvar text = \"twowords\"\n")
            try write("logic.go", "package example\nvar value = 2\nvar stable    = true\n")
            return try GitRepository(path: directory.path).load(.init(repository: directory.path, base: "main"))
        }.value
        let storeDirectory = directory.appendingPathComponent(".git/review")
        let store = try ReviewStore(directory: storeDirectory)
        let logic = try XCTUnwrap(snapshot.files.first { $0.path == "logic.go" })
        let format = try XCTUnwrap(snapshot.files.first { $0.path == "format.go" })
        let comment = ReviewComment(path: format.path, side: .new, startLine: 3, endLine: 3,
                                    text: "Keep this comment", fingerprint: format.fingerprint)
        let progress = ReviewProgress(reviewed: [logic.path: logic.fingerprint], comments: [comment])
        try store.saveProgress(progress, identity: snapshot.identity)
        let controller = ReviewWindowController(github: testGitHubClient())
        controller.start(store: store, arguments: ["--repo", directory.path])
        try await waitForReview(controller)
        let window = try XCTUnwrap(controller.window)
        window.isReleasedWhenClosed = false
        defer { window.delegate = nil; controller.close() }
        let content = try XCTUnwrap(window.contentView)
        let view = try XCTUnwrap(descendants(content).compactMap { $0 as? DiffViewport }.first)
        let checkbox = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }
            .first { $0.title == "Whitespace and imports" })
        func footerText() throws -> String {
            let footer = try XCTUnwrap(view.table.view(atColumn: 0, row: view.rows.count - 1,
                                                        makeIfNecessary: true) as? ReviewFooterView)
            return footer.message.stringValue
        }
        func stableLineKind() throws -> LineKind {
            let pair = try XCTUnwrap(view.rows.compactMap { row -> DiffPair? in
                guard view.files[row.file].path == logic.path, case .code(let pair) = row.content,
                      pair.new?.newNumber == 3 else { return nil }
                return pair
            }.first)
            return try XCTUnwrap(pair.new?.kind)
        }
        view.setExpanded(true, file: try XCTUnwrap(view.files.firstIndex { $0.path == logic.path }))
        XCTAssertEqual(checkbox.state, .on)
        XCTAssertFalse(view.isReviewed(format))
        XCTAssertTrue(view.expanded.contains(format.path))
        XCTAssertTrue(view.isReviewed(logic))
        XCTAssertEqual(try footerText(), "2 files left to review")
        XCTAssertEqual(try stableLineKind(), .addition)
        let skipCheckboxes = ["Tests", "Documentation and non-code", "Generated and noise", "Meta changes"].map { title in
            descendants(content).compactMap { $0 as? NSButton }.first { $0.title == title }
        }
        for checkbox in skipCheckboxes { XCTAssertEqual(try XCTUnwrap(checkbox).state, .off) }
        for included in [false, true, false, true] {
            checkbox.performClick(nil)
            XCTAssertEqual(checkbox.state == .on, included)
            XCTAssertEqual(view.isReviewed(format), !included)
            XCTAssertEqual(view.expanded.contains(format.path), included)
            XCTAssertTrue(view.isReviewed(logic))
            XCTAssertTrue(view.expanded.contains(logic.path))
            XCTAssertEqual(try stableLineKind(), included ? .addition : .context)
            XCTAssertEqual(try footerText(), included ? "2 files left to review" : "1 file left to review")
            XCTAssertEqual(try store.loadPreferences().filters.whitespaceAndImports, !included)
            for checkbox in skipCheckboxes { XCTAssertEqual(try XCTUnwrap(checkbox).state, .off) }
            XCTAssertEqual(try store.loadProgress(identity: snapshot.identity).reviewed, progress.reviewed)
            XCTAssertEqual(try store.loadProgress(identity: snapshot.identity).comments, [comment])
        }
        let reopened = ReviewWindowController(github: testGitHubClient())
        reopened.start(store: store, arguments: [])
        let reopenedWindow = try XCTUnwrap(reopened.window)
        reopenedWindow.isReleasedWhenClosed = false
        defer { reopenedWindow.delegate = nil; reopened.close() }
        let restored = try XCTUnwrap(descendants(try XCTUnwrap(reopenedWindow.contentView))
            .compactMap { $0 as? NSButton }.first { $0.title == checkbox.title })
        XCTAssertEqual(restored.state, .on)

        // No presentation host: a failed preference save must not display an alert in tests.
        controller.window = nil
        try FileManager.default.moveItem(at: storeDirectory, to: directory.appendingPathComponent(".git/saved-review"))
        try Data("not a directory".utf8).write(to: storeDirectory)
        checkbox.performClick(nil)
        XCTAssertEqual(checkbox.state, .on)
        XCTAssertFalse(view.isReviewed(format))
        XCTAssertTrue(view.expanded.contains(format.path))
        XCTAssertEqual(try footerText(), "2 files left to review")
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(reopenedWindow.isVisible)
        XCTAssertNil(window.attachedSheet)
    }

    @MainActor
    func testSavedExclusionChoicesProjectToInverseIncludeCheckboxesWithoutChangingPreferences() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReviewStore(directory: directory)
        for ignore in [true, false] {
            var preferences = ReviewPreferences()
            preferences.filters = ReviewFilters(tests: false, documentation: true, generated: false,
                                                whitespaceAndImports: ignore, metaChanges: ignore)
            try store.savePreferences(preferences)
            let controller = ReviewWindowController(github: testGitHubClient())
            controller.start(store: store, arguments: [])
            let window = try XCTUnwrap(controller.window)
            window.isReleasedWhenClosed = false
            defer { window.delegate = nil; controller.close() }
            let buttons = descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? NSButton }
            for (title, checked) in [
                ("Whitespace and imports", !ignore),
                ("Tests", true), ("Documentation and non-code", false), ("Generated and noise", true),
                ("Meta changes", !ignore)
            ] {
                XCTAssertEqual(try XCTUnwrap(buttons.first { $0.title == title }).state, checked ? .on : .off)
            }
            XCTAssertEqual(try store.loadPreferences().filters.whitespaceAndImports, ignore)
            XCTAssertEqual(try store.loadPreferences().filters.metaChanges, ignore)
            XCTAssertFalse(window.isVisible)
        }
    }
}
