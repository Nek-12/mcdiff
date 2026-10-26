import AppKit
import XCTest
@testable import McDiff
@testable import McDiffCore

final class ComparisonWarningTests: XCTestCase {
    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor
    private func ready(_ controller: ReviewWindowController) async throws {
        for _ in 0..<400 {
            if controller.isReviewReady { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Review did not load")
    }

    @MainActor
    func testAmbiguousHistoryShowsPersistentWarningAboveDiffAndClearsForDirectComparison() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Task.detached {
            @discardableResult
            func git(_ arguments: [String]) throws -> String {
                try ProcessRunner.run("/usr/bin/git", arguments, directory: directory.path).text.trimmingCharacters(in: .newlines)
            }
            func commit(_ filename: String) throws {
                try "let value = 1\n".write(to: directory.appendingPathComponent(filename), atomically: true, encoding: .utf8)
                try git(["add", "."])
                try git(["commit", "-m", filename])
            }
            try git(["init", "-b", "main"])
            try git(["config", "user.name", "Test"])
            try git(["config", "user.email", "test@example.com"])
            try git(["commit", "--allow-empty", "-m", "Initial"])
            try git(["checkout", "-b", "parent"])
            try commit("parent.swift")
            let earlierParent = try git(["rev-parse", "HEAD"])
            try git(["checkout", "main"])
            try commit("main.swift")
            let earlierMain = try git(["rev-parse", "HEAD"])
            try git(["checkout", "parent"])
            try git(["merge", "--no-ff", "-m", "parent merges main", earlierMain])
            try git(["checkout", "-b", "child", earlierMain])
            try git(["merge", "--no-ff", "-m", "child merges earlier parent", earlierParent])
            try commit("child.swift")
        }.value
        let store = try ReviewStore(directory: directory.appendingPathComponent(".git/reviews"))
        let controller = ReviewWindowController(github: testGitHubClient())
        let window = try XCTUnwrap(controller.window)
        defer { window.delegate = nil; controller.close() }
        controller.start(store: store, arguments: ["--repo", directory.path, "--base", "parent", "--target", "child"])
        try await ready(controller)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let warning = try XCTUnwrap(descendants(content).compactMap { $0 as? ComparisonWarningView }.first)
        let diff = try XCTUnwrap(descendants(content).compactMap { $0 as? DiffViewport }.first)
        XCTAssertFalse(warning.isHidden)
        XCTAssertGreaterThan(warning.bounds.height, 0)
        XCTAssertFalse(warning.convert(warning.bounds, to: content).intersects(diff.convert(diff.bounds, to: content)),
                       "The warning must reserve space, not cover source code")
        let label = try XCTUnwrap(descendants(warning).compactMap { $0 as? NSTextField }.first)
        XCTAssertTrue(label.stringValue.contains("Shared history is ambiguous"))
        XCTAssertTrue(label.stringValue.contains("inherited changes"))
        XCTAssertTrue(warning.toolTip?.contains("outside McDiff, then refresh") == true)
        XCTAssertTrue(warning.toolTip?.contains("Selected merge base:") == true)

        controller.showHome()
        XCTAssertTrue(warning.isHidden)
        controller.resumeReview()
        XCTAssertFalse(warning.isHidden)
        controller.load(.init(repository: directory.path, base: "parent", target: "child", mergeBase: false))
        XCTAssertTrue(warning.isHidden, "Loading a new destination must not retain the previous warning")
        try await ready(controller)
        XCTAssertTrue(warning.isHidden)
        XCTAssertNil(warning.toolTip)
        XCTAssertFalse(window.isVisible)
        XCTAssertNil(window.attachedSheet)
    }
}
