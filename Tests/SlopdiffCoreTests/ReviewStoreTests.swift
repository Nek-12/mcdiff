import XCTest
@testable import SlopdiffCore

final class ReviewStoreTests: XCTestCase {
    func testWrappingPreferenceRoundTripsAndMissingSettingKeepsExistingContent() throws {
        let preferences = ReviewPreferences(repositoryMappings: ["owner/repo": "/checkout"], softWrap: true)
        let decoded = try JSONDecoder().decode(ReviewPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertTrue(decoded.softWrap)
        XCTAssertEqual(decoded.repositoryMappings, preferences.repositoryMappings)
        let prior = Data(#"{"filters":{"tests":false,"documentation":true,"generated":false},"repositoryMappings":{"owner/repo":"/checkout"},"recentComparisons":[]}"#.utf8)
        let upgraded = try JSONDecoder().decode(ReviewPreferences.self, from: prior)
        XCTAssertFalse(upgraded.softWrap)
        XCTAssertFalse(upgraded.filters.tests)
        XCTAssertEqual(upgraded.repositoryMappings, preferences.repositoryMappings)
    }
    func testRoundTripAndCorruptDataIsNotDiscarded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slopdiff-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReviewStore(directory: directory)
        XCTAssertTrue(try store.loadProgress(identity: "../../not-a-path").comments.isEmpty)
        let comment = ReviewComment(path: "file.swift", side: .new, startLine: 2, endLine: 4, text: "Explain this\nplease", fingerprint: "first")
        try store.saveProgress(.init(reviewed: ["file.swift": "first"], comments: [comment]), identity: "../../not-a-path")
        let restored = try ReviewStore(directory: directory).loadProgress(identity: "../../not-a-path")
        XCTAssertEqual(restored.comments, [comment])
        XCTAssertEqual(restored.reviewed, ["file.swift": "first"])
        try store.savePreferences(.init(filters: .init(tests: false), repositoryMappings: ["owner/repo": "/local"]))
        XCTAssertEqual(try store.loadPreferences().repositoryMappings, ["owner/repo": "/local"])
        XCTAssertFalse(try store.loadPreferences().filters.tests)
        try Data("invalid json".utf8).write(to: directory.appendingPathComponent("preferences.json"))
        XCTAssertThrowsError(try store.loadPreferences())
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("preferences.json"), encoding: .utf8), "invalid json")
    }

    func testExportPreservesStaleAndMissingFileComments() {
        let snapshot = ReviewSnapshot(request: .init(repository: "/repo", base: "main"),
                                      identity: "review", title: "main → Working tree", baseRevision: "abc",
                                      targetRevision: nil, files: [])
        let progress = ReviewProgress(comments: [.init(path: "gone.swift", side: .old, startLine: 3, endLine: 6,
                                                       text: "Keep my feedback", fingerprint: "old")])
        let markdown = ReviewExport.markdown(snapshot: snapshot, progress: progress)
        XCTAssertTrue(markdown.contains("main → Working tree"))
        XCTAssertTrue(markdown.contains("Repository: /repo"))
        XCTAssertTrue(markdown.contains("Comparison: abc → Working tree"))
        XCTAssertTrue(markdown.contains("gone.swift · old · 3-6 (stale location)"))
        XCTAssertTrue(markdown.contains("Keep my feedback"))
        XCTAssertFalse(markdown.contains("```"))
    }

    func testPullRequestExportIncludesSourceAndResolvedComparison() {
        let request = ComparisonRequest(repository: "/checkout", base: "base", target: "head",
                                        pullRequestURL: "https://github.com/owner/repo/pull/7")
        let snapshot = ReviewSnapshot(request: request, identity: "pr", title: "owner/repo #7",
                                      baseRevision: "resolved-base", targetRevision: "resolved-head", files: [])
        let markdown = ReviewExport.markdown(snapshot: snapshot, progress: .init())
        XCTAssertTrue(markdown.contains("# Review: owner/repo #7"))
        XCTAssertTrue(markdown.contains("Comparison: resolved-base → resolved-head"))
        XCTAssertTrue(markdown.contains("Pull request: https://github.com/owner/repo/pull/7"))
    }
}
