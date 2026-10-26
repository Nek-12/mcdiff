import AppKit
@testable import McDiffCore
import XCTest
@testable import McDiff

final class ComparisonSheetTests: XCTestCase {
    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    @MainActor
    private func controls(_ sheet: ComparisonSheet) throws -> (NSPopUpButton, NSTextField, NSButton) {
        let views = descendants(of: try XCTUnwrap(sheet.window?.contentView))
        let tabs = try XCTUnwrap(views.compactMap { $0 as? NSSegmentedControl }.first)
        tabs.selectedSegment = 1
        tabs.sendAction(tabs.action, to: tabs.target)
        let repository = try XCTUnwrap(views.compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == "Choose a local Git checkout…" })
        repository.stringValue = "/tmp/review-checkout"
        return (
            try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first),
            try XCTUnwrap(views.compactMap { $0 as? NSTextField }
                .first { $0.placeholderString == "Tag, commit, or ref" }),
            try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "Open review" })
        )
    }

    @MainActor
    func testCustomTargetPassesTrimmedRevisionAndKeepsBase() throws {
        _ = NSApplication.shared
        for revision in ["v1.2.0", "abcdef123", "refs/remotes/origin/topic", "HEAD~3"] {
            var request: ComparisonRequest?
            let sheet = ComparisonSheet(recent: nil) { action in
                if case .open(let input) = action { request = try? input.resolve().request }
            }
            let (target, field, open) = try controls(sheet)
            XCTAssertEqual(target.titleOfSelectedItem, "Working tree")
            XCTAssertTrue(field.isHidden)
            target.selectItem(withTitle: "Revision…")
            target.sendAction(target.action, to: target.target)
            XCTAssertFalse(field.isHidden)
            field.stringValue = "  \(revision) \n"
            open.performClick(nil)
            XCTAssertEqual(request?.target, revision)
            XCTAssertEqual(request?.base, "main")
            XCTAssertEqual(request?.mergeBase, true)
        }
    }

    @MainActor
    func testReturningToWorkingTreeIgnoresCustomRevision() throws {
        _ = NSApplication.shared
        var request: ComparisonRequest?
        let sheet = ComparisonSheet(recent: nil) { action in
            if case .open(let input) = action { request = try? input.resolve().request }
        }
        let (target, field, open) = try controls(sheet)
        target.selectItem(withTitle: "Revision…")
        target.sendAction(target.action, to: target.target)
        field.stringValue = "HEAD~2"
        target.selectItem(withTitle: "Working tree")
        target.sendAction(target.action, to: target.target)
        XCTAssertTrue(field.isHidden)
        open.performClick(nil)
        XCTAssertNotNil(request)
        XCTAssertNil(request?.target)
    }

    func testComparisonInputRejectsInvalidInputsBeforeOpening() throws {
        XCTAssertThrowsError(try ComparisonInput.pullRequest("not a pull request").resolve())
        XCTAssertThrowsError(try ComparisonInput.local(repository: "", base: "main", target: nil, mergeBase: true).resolve())
        XCTAssertThrowsError(try ComparisonInput.local(repository: "/tmp/repo", base: " \n", target: nil, mergeBase: true).resolve())
        XCTAssertThrowsError(try ComparisonInput.local(repository: "/tmp/repo", base: "main", target: " \n", mergeBase: true).resolve())
        let result = try ComparisonInput.pullRequest(" https://github.com/owner/repo/pull/42 \n").resolve()
        XCTAssertEqual(result.url, "https://github.com/owner/repo/pull/42")
        XCTAssertNil(result.request)
    }

    @MainActor
    func testBranchUpdatesPreserveCustomRevisionAndEditedBase() throws {
        _ = NSApplication.shared
        let sheet = ComparisonSheet(recent: nil) { _ in }
        let (target, field, _) = try controls(sheet)
        let base = try XCTUnwrap(descendants(of: try XCTUnwrap(sheet.window?.contentView)).compactMap { $0 as? NSComboBox }.first)
        base.stringValue = "HEAD~4"
        target.selectItem(withTitle: "Revision…")
        target.sendAction(target.action, to: target.target)
        field.stringValue = "v1.0"
        sheet.setBranches(.init(branches: ["main", "topic"], defaultBase: "main"), chooseDefault: false)
        XCTAssertEqual(base.stringValue, "HEAD~4")
        XCTAssertEqual(target.titleOfSelectedItem, "Revision…")
        XCTAssertEqual(field.stringValue, "v1.0")
        XCTAssertFalse(field.isHidden)
        sheet.setBranches(.init(branches: ["main", "topic"], defaultBase: "topic"), chooseDefault: true)
        XCTAssertEqual(base.stringValue, "topic")
        XCTAssertEqual(target.titleOfSelectedItem, "Working tree")
        XCTAssertTrue(field.isHidden)
        XCTAssertFalse(try XCTUnwrap(sheet.window).isVisible)
    }

    func testBranchLoadingReportsRepositoryFailures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await ComparisonBranches.load(path: directory.path)
            XCTFail("A non-repository must not produce branch choices")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not a git repository"))
        }
        try await Task.detached {
            _ = try ProcessRunner.run("git", ["init", "-b", "main"], directory: directory.path)
            _ = try ProcessRunner.run("git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                "commit", "--allow-empty", "-m", "Initial"], directory: directory.path)
            _ = try ProcessRunner.run("git", ["branch", "topic"], directory: directory.path)
        }.value
        let result = try await ComparisonBranches.load(path: directory.path)
        XCTAssertTrue(result.branches.contains("topic"))
        XCTAssertEqual(result.defaultBase, "main")
    }
}
