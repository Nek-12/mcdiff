import XCTest
@testable import McDiff
@testable import McDiffCore

final class PreparedReviewTypeChangeTests: XCTestCase {
    func testLoadingReviewedTypeChangePreservesProgressCommentsAndBothPresentations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcdiff-prepared-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = GitRepository(path: root.path)
        _ = try git.git(["init", "-b", "main"])
        _ = try git.git(["config", "user.email", "test@example.invalid"])
        _ = try git.git(["config", "user.name", "Test"])
        let path = "file.md"
        let url = root.appendingPathComponent(path)
        try Data("# Before\nold content\n".utf8).write(to: url)
        _ = try git.git(["add", "."])
        _ = try git.git(["commit", "-m", "base"])
        let base = try git.revision("HEAD")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "target.md")
        _ = try git.git(["add", "."])
        _ = try git.git(["commit", "-m", "replace with link"])
        let request = ComparisonRequest(repository: root.path, base: base, target: "HEAD", mergeBase: false)
        let store = try ReviewStore(directory: root.appendingPathComponent("state"))
        let initial = try await PreparedReview.load(request, store: store)
        let file = try XCTUnwrap(initial.snapshot.files.first)
        let comment = ReviewComment(path: path, side: .old, startLine: 2, endLine: 2,
                                    text: "Keep the explanation", fingerprint: file.fingerprint)
        let progress = ReviewProgress(reviewed: [path: file.fingerprint], comments: [comment])
        try store.saveProgress(progress, identity: initial.snapshot.identity)
        let prepared = try await PreparedReview.load(request, store: store)
        XCTAssertEqual(prepared.snapshot.files.count, 1)
        XCTAssertEqual(prepared.progress.reviewed, progress.reviewed)
        XCTAssertEqual(prepared.progress.comments, [comment])
        XCTAssertNotNil(prepared.markdown[path])
        let rows = try XCTUnwrap(prepared.presentations[path])
        let pairs = rows.compactMap { row -> DiffPair? in
            if case let .code(pair) = row { return pair }
            return nil
        }
        XCTAssertEqual(pairs.compactMap { $0.old?.oldNumber }, [1, 2])
        XCTAssertEqual(pairs.compactMap { $0.new?.newNumber }, [1])
        XCTAssertEqual(try git.content(snapshot: prepared.snapshot, file: file, side: .old), "# Before\nold content\n")
        XCTAssertEqual(try git.content(snapshot: prepared.snapshot, file: file, side: .new), "target.md")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "different.md")
        _ = try git.git(["add", path])
        _ = try git.git(["commit", "-m", "update link"])
        let changed = try await PreparedReview.load(request, store: store)
        let changedFile = try XCTUnwrap(changed.snapshot.files.first)
        XCTAssertNotEqual(changedFile.fingerprint, file.fingerprint)
        XCTAssertEqual(changed.snapshot.identity, prepared.snapshot.identity)
        XCTAssertEqual(changed.progress.comments, [comment])
        XCTAssertNotEqual(changed.progress.reviewed[path], changedFile.fingerprint)
        XCTAssertTrue(ReviewExport.markdown(snapshot: changed.snapshot, progress: changed.progress).contains("(stale location)"))
    }
}
