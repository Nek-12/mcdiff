import XCTest
@testable import McDiffCore

final class ReviewStoreTests: XCTestCase {
    func testFinishPreservesExactSavedRoundAndComparisonThenReopensWithMarksOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcdiff-finish-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReviewStore(directory: directory)
        let snapshot = completedSnapshot()
        let progress = ReviewProgress(reviewed: ["file.swift": "prior", "gone.swift": "removed"], comments: [
            .init(path: "file.swift", side: .old, startLine: 2, endLine: 4, text: "Stale\nfeedback", fingerprint: "prior"),
            .init(path: "gone.swift", side: .new, startLine: 5, endLine: 5, text: "Keep deleted file feedback", fingerprint: "removed")
        ])
        try store.saveProgress(progress, identity: snapshot.identity)
        try store.saveProgress(.init(reviewed: ["other.swift": "other"]), identity: "other")
        try store.savePreferences(.init(repositoryMappings: ["owner/repo": "/checkout"], softWrap: true))
        let active = directory.appendingPathComponent("review-\(ReviewStore.digest(snapshot.identity)).json")
        let savedBytes = try Data(contentsOf: active)
        let preferences = try Data(contentsOf: directory.appendingPathComponent("preferences.json"))
        let before = Date()
        let archive = try store.finishReview(snapshot: snapshot)
        let metadata = try JSONDecoder().decode(CompletedReviewMetadata.self,
                                                from: Data(contentsOf: archive.appendingPathComponent("metadata.json")))
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("progress.json")), savedBytes)
        let archivedProgress = try JSONDecoder().decode(ReviewProgress.self,
                                                        from: Data(contentsOf: archive.appendingPathComponent("progress.json")))
        XCTAssertEqual(archivedProgress.reviewed, progress.reviewed)
        XCTAssertEqual(archivedProgress.comments, progress.comments)
        XCTAssertEqual(metadata.id.uuidString, archive.lastPathComponent)
        XCTAssertGreaterThanOrEqual(metadata.completedAt, before)
        XCTAssertLessThanOrEqual(metadata.completedAt, Date())
        XCTAssertEqual(metadata.comparisonIdentity, snapshot.identity)
        XCTAssertEqual(metadata.title, snapshot.title)
        XCTAssertEqual(metadata.request, snapshot.request)
        XCTAssertEqual(metadata.baseRevision, snapshot.baseRevision)
        XCTAssertEqual(metadata.targetRevision, snapshot.targetRevision)
        XCTAssertEqual(metadata.fileFingerprints, ["file.swift": "current"])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("preferences.json")), preferences)
        let reopened = try ReviewStore(directory: directory)
        XCTAssertTrue(try reopened.loadProgress(identity: snapshot.identity).comments.isEmpty)
        XCTAssertEqual(try reopened.loadProgress(identity: snapshot.identity).reviewed, progress.reviewed)
        XCTAssertEqual(try reopened.loadProgress(identity: "other").reviewed, ["other.swift": "other"])

        let next = ReviewProgress(reviewed: ["file.swift": "current"])
        try reopened.saveProgress(next, identity: snapshot.identity)
        let second = try reopened.finishReview(snapshot: snapshot)
        XCTAssertNotEqual(second, archive)
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("progress.json")), savedBytes)
        let secondProgress = try JSONDecoder().decode(ReviewProgress.self,
                                                     from: Data(contentsOf: second.appendingPathComponent("progress.json")))
        XCTAssertEqual(secondProgress.reviewed, next.reviewed)
        XCTAssertTrue(secondProgress.comments.isEmpty)
        XCTAssertEqual(try reopened.loadProgress(identity: snapshot.identity).reviewed, next.reviewed)
    }

    func testFinishNeverSavedWorkingTreeReviewArchivesEmptyRound() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcdiff-empty-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReviewStore(directory: directory)
        let snapshot = ReviewSnapshot(request: .init(repository: "/checkout", base: "main"),
                                      identity: "../../empty", title: "Working tree", baseRevision: "base",
                                      targetRevision: nil, files: [])
        let archive = try store.finishReview(snapshot: snapshot)
        let metadata = try JSONDecoder().decode(CompletedReviewMetadata.self,
                                                from: Data(contentsOf: archive.appendingPathComponent("metadata.json")))
        let progress = try JSONDecoder().decode(ReviewProgress.self,
                                               from: Data(contentsOf: archive.appendingPathComponent("progress.json")))
        XCTAssertNil(metadata.targetRevision)
        XCTAssertTrue(metadata.fileFingerprints.isEmpty)
        XCTAssertTrue(progress.comments.isEmpty)
        XCTAssertTrue(progress.reviewed.isEmpty)
        XCTAssertNotEqual(try store.finishReview(snapshot: snapshot), archive)
    }

    func testFinishPreparationFailurePreservesActiveProgressAndPreferences() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcdiff-failed-finish-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReviewStore(directory: directory)
        let snapshot = completedSnapshot()
        try store.saveProgress(.init(reviewed: ["file.swift": "current"]), identity: snapshot.identity)
        try store.savePreferences(.init(softWrap: true))
        let active = directory.appendingPathComponent("review-\(ReviewStore.digest(snapshot.identity)).json")
        let original = try Data(contentsOf: active)
        let preferences = try Data(contentsOf: directory.appendingPathComponent("preferences.json"))
        try Data("blocking file".utf8).write(to: directory.appendingPathComponent("completed-reviews"))
        XCTAssertThrowsError(try store.finishReview(snapshot: snapshot))
        XCTAssertThrowsError(try store.resetReview(snapshot: snapshot))
        XCTAssertEqual(try Data(contentsOf: active), original)
        XCTAssertEqual(try store.loadProgress(identity: snapshot.identity).reviewed, ["file.swift": "current"])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("preferences.json")), preferences)
    }

    func testFinishCommitFailurePreservesActiveProgress() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcdiff-commit-failure-\(UUID())")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try ReviewStore(directory: directory)
        let snapshot = completedSnapshot()
        try store.saveProgress(.init(reviewed: ["file.swift": "current"]), identity: snapshot.identity)
        let active = directory.appendingPathComponent("review-\(ReviewStore.digest(snapshot.identity)).json")
        let original = try Data(contentsOf: active)
        let archives = directory.appendingPathComponent("completed-reviews")
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: false)
        // The historical round can be written inside the writable archive parent,
        // but active progress cannot be atomically replaced in its read-only parent.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try store.finishReview(snapshot: snapshot))
        XCTAssertThrowsError(try store.resetReview(snapshot: snapshot))
        XCTAssertEqual(try Data(contentsOf: active), original)
        XCTAssertEqual(try store.loadProgress(identity: snapshot.identity).reviewed, ["file.swift": "current"])
        let prepared = try FileManager.default.contentsOfDirectory(at: archives, includingPropertiesForKeys: nil)
        XCTAssertEqual(prepared.count, 2)
        for archive in prepared {
            XCTAssertTrue(FileManager.default.fileExists(atPath: archive.appendingPathComponent("metadata.json").path))
            XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("progress.json")), original)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let completed = try store.finishReview(snapshot: snapshot)
        XCTAssertEqual(try Data(contentsOf: completed.appendingPathComponent("progress.json")), original)
    }

    func testTenRoundsAcrossRelaunchesKeepOnlyMatchingManualMarksAndArchiveComments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcdiff-rounds-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try ProcessRunner.run("git", ["init", "-b", "main"], directory: directory.path)
        _ = try ProcessRunner.run("git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
            "commit", "--allow-empty", "-m", "Initial"], directory: directory.path)
        for path in ["unchanged.swift", "changed.swift", "unchecked.swift"] {
            try Data("let value = 1\n".utf8).write(to: directory.appendingPathComponent(path))
        }
        let request = ComparisonRequest(repository: directory.path, base: "main")
        let storage = directory.appendingPathComponent(".git/reviews")
        var store = try ReviewStore(directory: storage)
        let initial = try GitRepository(path: directory.path).load(request)
        var expectedMarks = Dictionary(uniqueKeysWithValues: initial.files
            .filter { $0.path != "unchecked.swift" }.map { ($0.path, $0.fingerprint) })
        try store.saveProgress(.init(reviewed: expectedMarks), identity: initial.identity)

        for round in 1...10 {
            if round == 5 {
                try Data("let value = 2\n".utf8).write(to: directory.appendingPathComponent("changed.swift"))
            }
            let snapshot = try GitRepository(path: directory.path).load(request)
            XCTAssertEqual(snapshot.identity, initial.identity)
            var progress = try store.loadProgress(identity: snapshot.identity)
            if round == 8 {
                progress.reviewed.removeValue(forKey: "unchanged.swift")
                expectedMarks.removeValue(forKey: "unchanged.swift")
            }
            let changed = try XCTUnwrap(snapshot.files.first { $0.path == "changed.swift" })
            XCTAssertEqual(progress.reviewed[changed.path] == changed.fingerprint, round < 5)
            let comment = ReviewComment(path: changed.path, side: .new, startLine: 1, endLine: 1,
                                        text: "Round \(round)", fingerprint: changed.fingerprint)
            progress.comments = [comment]
            try store.saveProgress(progress, identity: snapshot.identity)
            let archive = try store.finishReview(snapshot: snapshot)
            let archived = try JSONDecoder().decode(ReviewProgress.self,
                from: Data(contentsOf: archive.appendingPathComponent("progress.json")))
            XCTAssertEqual(archived.comments, [comment])
            XCTAssertEqual(archived.reviewed, expectedMarks)
            store = try ReviewStore(directory: storage)
            let reopened = try store.loadProgress(identity: snapshot.identity)
            XCTAssertTrue(reopened.comments.isEmpty)
            XCTAssertEqual(reopened.reviewed, expectedMarks)
            XCTAssertNil(reopened.reviewed["unchecked.swift"])
        }
    }

    func testResetArchivesThenClearsMarksAndCommentsAcrossRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcdiff-reset-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReviewStore(directory: directory)
        let snapshot = completedSnapshot()
        let progress = ReviewProgress(reviewed: ["file.swift": "current"], comments: [
            .init(path: "file.swift", side: .new, startLine: 1, endLine: 1, text: "Feedback", fingerprint: "current")
        ])
        try store.saveProgress(progress, identity: snapshot.identity)
        let archive = try store.resetReview(snapshot: snapshot)
        let archived = try JSONDecoder().decode(ReviewProgress.self,
            from: Data(contentsOf: archive.appendingPathComponent("progress.json")))
        XCTAssertEqual(archived.reviewed, progress.reviewed)
        XCTAssertEqual(archived.comments, progress.comments)
        let reopened = try ReviewStore(directory: directory).loadProgress(identity: snapshot.identity)
        XCTAssertTrue(reopened.reviewed.isEmpty)
        XCTAssertTrue(reopened.comments.isEmpty)
    }

    func testFinishRejectsCorruptActiveDataWithoutDiscardingIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcdiff-corrupt-finish-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReviewStore(directory: directory)
        let snapshot = completedSnapshot()
        let active = directory.appendingPathComponent("review-\(ReviewStore.digest(snapshot.identity)).json")
        let corrupt = Data("invalid json".utf8)
        try corrupt.write(to: active)
        XCTAssertThrowsError(try store.finishReview(snapshot: snapshot))
        XCTAssertThrowsError(try store.loadProgress(identity: snapshot.identity))
        XCTAssertEqual(try Data(contentsOf: active), corrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("completed-reviews").path))
    }

    private func completedSnapshot() -> ReviewSnapshot {
        ReviewSnapshot(request: .init(repository: "/checkout", base: "main", target: "feature",
                                      pullRequestURL: "https://github.com/owner/repo/pull/7"),
                       identity: "comparison", title: "owner/repo #7", baseRevision: "resolved-base",
                       targetRevision: "resolved-head",
                       files: [.init(path: "file.swift", hunks: [], fingerprint: "current")])
    }

    func testDiffLayoutIsRememberedWithoutChangingReviewPreferences() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcdiff-layout-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReviewStore(directory: directory)
        var preferences = ReviewPreferences(filters: .init(tests: false), repositoryMappings: ["owner/repo": "/checkout"],
                                            softWrap: true, diffLayout: .unified)
        try store.savePreferences(preferences)
        let restored = try ReviewStore(directory: directory).loadPreferences()
        XCTAssertEqual(restored.diffLayout, .unified)
        XCTAssertTrue(restored.softWrap)
        XCTAssertFalse(restored.filters.tests)
        XCTAssertEqual(restored.repositoryMappings, preferences.repositoryMappings)
        preferences.diffLayout = .split
        try store.savePreferences(preferences)
        XCTAssertEqual(try store.loadPreferences().diffLayout, .split)
    }
    func testWrappingPreferenceRoundTripsAndMissingSettingKeepsExistingContent() throws {
        let preferences = ReviewPreferences(repositoryMappings: ["owner/repo": "/checkout"], softWrap: true)
        let decoded = try JSONDecoder().decode(ReviewPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertTrue(decoded.softWrap)
        XCTAssertEqual(decoded.repositoryMappings, preferences.repositoryMappings)
        let prior = Data(#"{"filters":{"tests":false,"documentation":true,"generated":false},"repositoryMappings":{"owner/repo":"/checkout"},"recentComparisons":[]}"#.utf8)
        let upgraded = try JSONDecoder().decode(ReviewPreferences.self, from: prior)
        XCTAssertFalse(upgraded.softWrap)
        XCTAssertEqual(upgraded.diffLayout, .split)
        XCTAssertFalse(upgraded.filters.tests)
        XCTAssertEqual(upgraded.repositoryMappings, preferences.repositoryMappings)
    }
    func testRoundTripAndCorruptDataIsNotDiscarded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcdiff-store-\(UUID())")
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
