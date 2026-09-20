import XCTest
@testable import McDiffCore

final class GitRepositoryTests: XCTestCase {
    private var root: URL!
    private var repo: GitRepository!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mcdiff-git-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repo = GitRepository(path: root.path)
        _ = try repo.git(["init", "-b", "main"])
        _ = try repo.git(["config", "user.email", "test@example.invalid"])
        _ = try repo.git(["config", "user.name", "Test"])
        try write("tracked.swift", "base\n")
        try write(".gitignore", "*.ignored\n")
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "base"])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(path))
    }
    private func load(base: String = "main", target: String? = nil, mergeBase: Bool = true) throws -> ReviewSnapshot {
        try repo.load(.init(repository: root.path, base: base, target: target, mergeBase: mergeBase))
    }

    func testWorktreeIncludesCommittedStagedUnstagedAndUntrackedWithoutIndexMutation() throws {
        _ = try repo.git(["checkout", "-b", "feature"])
        try write("committed.swift", "committed\n")
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "feature"])
        try write("staged.swift", "staged\n")
        _ = try repo.git(["add", "."])
        try write("tracked.swift", "unstaged\n")
        try write("new \"odd\"\t😀\n.swift", "new\n")
        try write("skip.ignored", "hidden\n")
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let snapshot = try load()
        XCTAssertEqual(Set(snapshot.files.map(\.path)), ["committed.swift", "staged.swift", "tracked.swift", "new \"odd\"\t😀\n.swift"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(snapshot.targetRevision, nil)
    }

    func testExplicitRevisionsIgnoreWorkingTreeAndKeepResolvedContent() throws {
        try write("tracked.swift", "committed\n")
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "second"])
        let snapshot = try load(base: "HEAD~1", target: "HEAD", mergeBase: false)
        try write("tracked.swift", "uncommitted\n")
        XCTAssertEqual(try repo.content(snapshot: snapshot, file: snapshot.files[0], side: .old), "base\n")
        XCTAssertEqual(try repo.content(snapshot: snapshot, file: snapshot.files[0], side: .new), "committed\n")
    }

    func testProgressIdentitySurvivesWorktreeAndPullRequestUpdates() throws {
        try write("tracked.swift", "first\n")
        let first = try load()
        try write("tracked.swift", "second\n")
        let second = try load()
        XCTAssertEqual(first.identity, second.identity)
        XCTAssertNotEqual(first.files[0].fingerprint, second.files[0].fingerprint)
        let old = try repo.load(.init(repository: root.path, base: "main", target: "HEAD", pullRequestURL: "https://github.com/o/r/pull/1"))
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "update"])
        let updated = try repo.load(.init(repository: root.path, base: "HEAD~1", target: "main", pullRequestURL: "https://github.com/o/r/pull/1"))
        XCTAssertEqual(old.identity, updated.identity)
        XCTAssertEqual(updated.title, "o/r #1")
    }

    func testMergeBaseExcludesChangesOnlyOnBaseBranch() throws {
        _ = try repo.git(["checkout", "-b", "feature"])
        try write("feature.swift", "feature\n")
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "feature"])
        _ = try repo.git(["checkout", "main"])
        try write("main.swift", "main\n")
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "main"])
        let snapshot = try load(target: "feature")
        XCTAssertEqual(snapshot.files.map(\.path), ["feature.swift"])
    }

    func testRenameDeletionModeAndBinaryChanges() throws {
        try write("gone.swift", "gone\n")
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("binary.bin"))
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "more"])
        _ = try repo.git(["mv", "tracked.swift", "renamed.swift"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("gone.swift"))
        try Data([0, 3, 4]).write(to: root.appendingPathComponent("binary.bin"))
        let snapshot = try load()
        XCTAssertEqual(snapshot.files.first { $0.path == "renamed.swift" }?.oldPath, "tracked.swift")
        XCTAssertEqual(snapshot.files.first { $0.path == "gone.swift" }?.status, "D")
        XCTAssertEqual(snapshot.files.first { $0.path == "binary.bin" }?.isBinary, true)
        let before = try XCTUnwrap(snapshot.files.first { $0.path == "binary.bin" }?.fingerprint)
        try Data([0, 5, 6]).write(to: root.appendingPathComponent("binary.bin"))
        XCTAssertNotEqual(try load().files.first { $0.path == "binary.bin" }?.fingerprint, before)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("renamed.swift").path)
        XCTAssertNotEqual(try load().files.first { $0.path == "renamed.swift" }?.fingerprint,
                          snapshot.files.first { $0.path == "renamed.swift" }?.fingerprint)
    }

    func testUntrackedSymlinkDoesNotReadDestination() throws {
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("secret-link").path,
                                                  withDestinationPath: "/etc/passwd")
        let snapshot = try load()
        let file = try XCTUnwrap(snapshot.files.first { $0.path == "secret-link" })
        XCTAssertEqual(file.hunks.flatMap(\.lines).filter { $0.kind == .addition }.map(\.text), ["/etc/passwd"])
        XCTAssertEqual(try repo.content(snapshot: snapshot, file: file, side: .new), "/etc/passwd")
    }

    func testUntrackedBinaryEmptyFileAndModeFingerprints() throws {
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("new.bin"))
        try write("empty.kt", "")
        try write("script.sh", "echo hello\n")
        let before = try load()
        XCTAssertEqual(before.files.first { $0.path == "new.bin" }?.isBinary, true)
        XCTAssertEqual(before.files.first { $0.path == "empty.kt" }?.status, "A")
        XCTAssertEqual(before.files.first { $0.path == "empty.kt" }?.hunks, [])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("script.sh").path)
        try Data([0, 3, 4]).write(to: root.appendingPathComponent("new.bin"))
        let after = try load()
        for name in ["new.bin", "script.sh"] {
            XCTAssertNotEqual(before.files.first { $0.path == name }?.fingerprint, after.files.first { $0.path == name }?.fingerprint)
        }
    }

    func testMissingAndOptionLikeRefsFailWithCommandDiagnostics() throws {
        for ref in ["missing-branch", "--output=/tmp/mcdiff-unwanted"] {
            XCTAssertThrowsError(try load(base: ref)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Command:"))
                XCTAssertTrue(error.localizedDescription.contains("stderr:"))
            }
        }
    }

    func testExternalDiffAndTextConversionAreNeverRun() throws {
        _ = try repo.git(["config", "diff.external", "/definitely/not/a/program"])
        _ = try repo.git(["config", "diff.custom.textconv", "/definitely/not/a/program"])
        try write(".gitattributes", "*.swift diff=custom\n")
        try write("tracked.swift", "changed\n")
        XCTAssertTrue(try load().files.contains { $0.path == "tracked.swift" })
    }

    func testFormattingClassificationUsesWholeFilesAndPreservesSemanticWhitespaceAndModes() throws {
        let initial: [String: String] = [
            "Odd \"path\"\t\n.kt": "fun example() {\nval value = 1\n}\n",
            "literal.kt": "val text = \"two words\"\n",
            "raw.kt": "val text = \"\"\"\n" + String(repeating: "context\n", count: 10) + "two words\n\"\"\"\n",
            "indent.py": "if True:\n print('yes')\n",
            "mode.kt": "val value = 1\n"
        ]
        for (name, text) in initial { try write(name, text) }
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "format baseline"])
        try write("Odd \"path\"\t\n.kt", "fun example() {\n    val value = 1\n}\n")
        try write("literal.kt", "val text = \"two  words\"\n")
        try write("raw.kt", initial["raw.kt"]!.replacingOccurrences(of: "two words", with: "two  words"))
        try write("indent.py", "if True:\n  print('yes')\n")
        try write("mode.kt", "val  value = 1\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("mode.kt").path)
        let snapshot = try load()
        XCTAssertEqual(snapshot.files.first { $0.path == "Odd \"path\"\t\n.kt" }?.isFormattingOnly, true)
        for name in ["literal.kt", "raw.kt", "indent.py", "mode.kt"] {
            XCTAssertEqual(snapshot.files.first { $0.path == name }?.isFormattingOnly, false, name)
        }
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "format changes"])
        let committed = try load(base: "HEAD~1", target: "HEAD", mergeBase: false)
        XCTAssertEqual(committed.files.first { $0.path == "Odd \"path\"\t\n.kt" }?.isFormattingOnly, true)
    }

    func testProcessDrainsBothStreamsAndTimesOutWithDiagnostics() throws {
        let output = try ProcessRunner.run("sh", ["-c", "i=0; while [ \"$i\" -lt 12000 ]; do echo stdout; echo stderr >&2; i=$((i+1)); done"], directory: root.path)
        XCTAssertGreaterThan(output.data.count, 65_536)
        XCTAssertGreaterThan(output.stderr.count, 65_536)
        let start = Date()
        XCTAssertThrowsError(try ProcessRunner.run("sh", ["-c", "echo before; echo problem >&2; exec sleep 5"], directory: root.path, timeout: 0.1)) { error in
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
            XCTAssertTrue(error.localizedDescription.contains("before"))
            XCTAssertTrue(error.localizedDescription.contains("problem"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testGitHubURLParsingAndWrongRepositoryRejection() throws {
        let pr = try GitHubPR.parse("https://github.com/owner/repo/pull/123/files")
        XCTAssertEqual(pr.repositoryKey, "owner/repo")
        XCTAssertEqual(pr.url, "https://github.com/owner/repo/pull/123")
        for invalid in ["https://evil.com/owner/repo/pull/1", "https://github.com/owner/repo/issues/1",
                        "https://github.com/owner/repo/pull/-2"] {
            XCTAssertThrowsError(try GitHubPR.parse(invalid))
        }
        let revisions = try GitHubPRRevisions(base: String(repeating: "a", count: 40), head: String(repeating: "b", count: 40))
        XCTAssertThrowsError(try pr.resolve(localRepository: root.path, revisions: revisions)) { error in
            XCTAssertTrue(error.localizedDescription.contains("no GitHub remote"))
        }
    }

    func testGitHubFetchesExactMissingObjectsWithoutChangingBranchesIndexOrWorkingFiles() throws {
        let upstream = FileManager.default.temporaryDirectory.appendingPathComponent("mcdiff-pr-upstream-\(UUID())")
        defer { try? FileManager.default.removeItem(at: upstream) }
        _ = try ProcessRunner.run("git", ["clone", "--no-hardlinks", root.path, upstream.path], directory: root.path)
        let source = GitRepository(path: upstream.path)
        _ = try source.git(["config", "user.email", "test@example.invalid"])
        _ = try source.git(["config", "user.name", "Test"])
        let base = try source.revision("HEAD")
        try Data("pull request\n".utf8).write(to: upstream.appendingPathComponent("tracked.swift"))
        _ = try source.git(["commit", "-am", "PR change"])
        let head = try source.revision("HEAD")
        _ = try repo.git(["remote", "add", "origin", "https://github.com/owner/repo.git"])
        _ = try repo.git(["config", "url.\(upstream.absoluteString).insteadOf", "https://github.com/owner/repo.git"])
        try write("staged.swift", "staged local\n")
        _ = try repo.git(["add", "staged.swift"])
        try write("tracked.swift", "local working change\n")
        try write("untracked.swift", "untracked local\n")
        let refs = try repo.git(["show-ref"]).data
        let status = try repo.git(["status", "--porcelain=v1", "-z"]).data
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let branch = try repo.git(["symbolic-ref", "HEAD"]).text
        let pr = try GitHubPR.parse("https://github.com/owner/repo/pull/123")
        let revisions = try GitHubPRRevisions(base: base, head: head)
        let request = try pr.resolve(localRepository: root.path, revisions: revisions)
        XCTAssertEqual(request.base, base)
        XCTAssertEqual(request.target, head)
        XCTAssertEqual(try repo.revision(head), head)
        XCTAssertEqual(try repo.git(["show-ref"]).data, refs)
        XCTAssertEqual(try repo.git(["symbolic-ref", "HEAD"]).text, branch)
        XCTAssertEqual(try repo.git(["status", "--porcelain=v1", "-z"]).data, status)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("tracked.swift"), encoding: .utf8), "local working change\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/FETCH_HEAD").path))
    }

    func testGitHubMatchesAliasesExpandedToGitHub() throws {
        _ = try repo.git(["remote", "add", "origin", "work:owner/repo.git"])
        _ = try repo.git(["config", "url.https://github.com/.insteadOf", "work:"])
        let sha = try repo.revision("HEAD")
        let pr = try GitHubPR.parse("https://github.com/owner/repo/pull/123")
        let request = try pr.resolve(localRepository: root.path, revisions: GitHubPRRevisions(base: sha, head: sha))
        XCTAssertEqual(request.base, sha)
        XCTAssertEqual(request.target, sha)
    }

    func testLargeTrackedReview() throws {
        let old = (0..<75).map { "val item\($0) = \($0)\n" }.joined()
        let new = (0..<75).map { "val item\($0) = \($0 + 1)\n" }.joined()
        for index in 0..<400 { try write("Source\(index).kt", old) }
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "400 file baseline"])
        for index in 0..<400 { try write("Source\(index).kt", new) }
        let start = ProcessInfo.processInfo.systemUptime
        let snapshot = try load()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertEqual(snapshot.files.count, 400)
        XCTAssertEqual(snapshot.files.reduce(0) { $0 + $1.additions }, 30_000)
        XCTAssertEqual(snapshot.files.reduce(0) { $0 + $1.deletions }, 30_000)
        print("Backend stress: 400 files / 30,000 source lines / 60,000 changed diff lines loaded in \(elapsed) seconds")
    }

    func testLargeUntrackedReview() throws {
        let contents = (0..<75).map { "val item\($0) = \($0)\n" }.joined()
        for index in 0..<400 { try write("Source\(index).kt", contents) }
        let start = ProcessInfo.processInfo.systemUptime
        let snapshot = try load()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertEqual(snapshot.files.count, 400)
        XCTAssertEqual(snapshot.files.reduce(0) { $0 + $1.additions }, 30_000)
        XCTAssertEqual(snapshot.files.reduce(0) { $0 + $1.deletions }, 0)
        print("Backend untracked stress: 400 files / 30,000 added lines loaded in \(elapsed) seconds")
    }
}
