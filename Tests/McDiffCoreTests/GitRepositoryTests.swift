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
        XCTAssertNil(snapshot.warning)
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

    func testUnchangedSectionsLoadIndividuallyWithOriginalNumbersAndPreservedIdentity() throws {
        let path = "context \"odd\"\t\n.swift"
        let original = (1...45).map { "let value\($0) = \($0)\r" }
        try write(path, original.joined(separator: "\n")) // CRLF, no final LF.
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "context"])
        var changed = original
        changed[9] = "let value10 = 100\r"
        changed.insert("let inserted = true\r", at: 30)
        try write(path, changed.joined(separator: "\n"))
        let snapshot = try load()
        let file = try XCTUnwrap(snapshot.files.first { $0.path == path })
        XCTAssertEqual(file.hunks.count, 2)
        let sections = file.unchangedSections
        XCTAssertEqual(sections.map(\.beforeHunkIndex), [0, 1, 2])
        XCTAssertEqual(sections.first?.oldStart, 0)
        XCTAssertNil(sections.last?.count)
        let fingerprint = file.fingerprint
        var shownOld = file.hunks.flatMap(\.lines).compactMap(\.oldNumber)
        var shownNew = file.hunks.flatMap(\.lines).compactMap(\.newNumber)
        for section in sections {
            let pairs = try repo.unchangedLines(snapshot: snapshot, file: file, section: section)
            XCTAssertFalse(pairs.isEmpty)
            for pair in pairs {
                let line = try XCTUnwrap(pair.old)
                XCTAssertEqual(pair.old, pair.new)
                XCTAssertEqual(line.kind, .context)
                XCTAssertEqual(line.text, original[try XCTUnwrap(line.oldNumber) - 1])
                XCTAssertEqual(line.text, changed[try XCTUnwrap(line.newNumber) - 1])
            }
            shownOld += pairs.compactMap { $0.old?.oldNumber }
            shownNew += pairs.compactMap { $0.new?.newNumber }
        }
        XCTAssertEqual(shownOld.sorted(), Array(1...original.count))
        XCTAssertEqual(shownNew.sorted(), Array(1...changed.count))
        XCTAssertEqual(file.fingerprint, fingerprint)
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "changes"])
        let committed = try load(base: "HEAD~1", target: "HEAD", mergeBase: false)
        let committedFile = try XCTUnwrap(committed.files.first { $0.path == path })
        try write(path, "unrelated live content")
        XCTAssertFalse(try repo.unchangedLines(snapshot: committed, file: committedFile,
                                             section: committedFile.unchangedSections[0]).isEmpty)
    }

    func testUnchangedSectionRejectsLiveEditsInPatchOtherSectionsAndAtEOF() throws {
        let original = (1...40).map { "line \($0)" }
        try write("tracked.swift", original.joined(separator: "\n") + "\n")
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "context"])
        var changed = original
        changed[15] = "changed line"
        let source = changed.joined(separator: "\n") + "\n"
        try write("tracked.swift", source)
        let snapshot = try load()
        let file = try XCTUnwrap(snapshot.files.first)
        let first = try XCTUnwrap(file.unchangedSections.first)
        for index in [0, 15, 39] {
            var stale = changed
            stale[index] = "edited after loading"
            try write("tracked.swift", stale.joined(separator: "\n") + "\n")
            XCTAssertThrowsError(try repo.unchangedLines(snapshot: snapshot, file: file, section: first))
            XCTAssertThrowsError(try repo.contextPresentation(snapshot: snapshot, file: file))
        }
        for stale in [source + "new trailing line\n", String(source.dropLast()), changed.dropLast().joined(separator: "\n")] {
            try write("tracked.swift", stale)
            XCTAssertThrowsError(try repo.unchangedLines(snapshot: snapshot, file: file, section: first))
            XCTAssertThrowsError(try repo.contextPresentation(snapshot: snapshot, file: file))
        }
        try write("tracked.swift", source)
        XCTAssertFalse(try repo.unchangedLines(snapshot: snapshot, file: file, section: first).isEmpty)
        XCTAssertFalse(try repo.contextPresentation(snapshot: snapshot, file: file).isEmpty)
    }

    func testResolvedImportsLeaveOnlyOrdinaryContextDisclosuresAndValidateTheirSubranges() throws {
        let old = ["package sample", "", "import ("] + (1...40).map { "\t\"module\($0)\"" } +
            [")", "", "func main() {}"] + (1...10).map { "// remaining \($0)" }
        try write("source.go", old.joined(separator: "\n") + "\n")
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "imports"])
        var new = old
        new[12] = "\t\"replacement10\""
        new[30] = "\t\"replacement28\""
        try write("source.go", new.joined(separator: "\n") + "\n")
        let snapshot = try load()
        let file = try XCTUnwrap(snapshot.files.first)
        let rows = try repo.contextPresentation(snapshot: snapshot, file: file)
        let imports = rows.compactMap { row -> [DiffPair]? in
            if case .imports(let pairs) = row { return pairs }; return nil
        }
        XCTAssertEqual(imports.count, 1)
        XCTAssertEqual(imports.first?.compactMap { $0.new?.newNumber }, Array(1...44))
        let sections = rows.compactMap { row -> UnchangedSection? in
            if case .context(let section) = row { return section }; return nil
        }
        let tail = try XCTUnwrap(sections.last)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(tail.oldStart, 44)
        let remainder = try repo.unchangedLines(snapshot: snapshot, file: file, section: tail)
        XCTAssertEqual(remainder.compactMap { $0.new?.text }, Array(new.dropFirst(44)))
        let invalid = UnchangedSection(beforeHunkIndex: tail.beforeHunkIndex,
                                       oldStart: tail.oldStart, newStart: tail.newStart + 1, count: 2)
        XCTAssertThrowsError(try repo.unchangedLines(snapshot: snapshot, file: file, section: invalid))
        let oversized = UnchangedSection(beforeHunkIndex: tail.beforeHunkIndex,
                                         oldStart: tail.oldStart, newStart: tail.newStart, count: Int.max)
        XCTAssertThrowsError(try repo.unchangedLines(snapshot: snapshot, file: file, section: oversized))
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "changed imports"])
        let committed = try load(base: "HEAD~1", target: "HEAD", mergeBase: false)
        try write("source.go", "changed worktree")
        XCTAssertFalse(try repo.contextPresentation(snapshot: committed, file: committed.files[0]).isEmpty)
    }

    func testMetadataOnlyRenameExposesWholeFileButAddedDeletedBinaryDoNot() throws {
        try write("original.swift", "first\nsecond")
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("binary"))
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "files"])
        _ = try repo.git(["mv", "original.swift", "renamed.swift"])
        _ = try repo.git(["rm", "tracked.swift"])
        try write("added.swift", "addition")
        try Data([0, 3, 4]).write(to: root.appendingPathComponent("binary"))
        let snapshot = try load()
        for file in snapshot.files {
            if file.path == "renamed.swift" {
                XCTAssertTrue(file.hunks.isEmpty)
                let section = try XCTUnwrap(file.unchangedSections.first)
                XCTAssertEqual(file.unchangedSections.count, 1)
                XCTAssertEqual(try repo.unchangedLines(snapshot: snapshot, file: file, section: section).compactMap { $0.new?.text },
                               ["first", "second"])
            } else {
                XCTAssertTrue(file.unchangedSections.isEmpty, file.path)
            }
        }
    }

    func testZeroContextInsertionDeletionAndEOFSections() throws {
        _ = try repo.git(["config", "diff.context", "0"])
        let original = (1...12).map { "line \($0)" }
        try write("tracked.swift", original.joined(separator: "\n") + "\n")
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "context"])
        for changed in [
            ["first"] + original,
            Array(original.dropFirst()),
            Array(original.prefix(5)) + ["inserted"] + original.dropFirst(5),
            Array(original.prefix(5)) + original.dropFirst(6),
            original + ["last"],
            Array(original.dropLast())
        ] {
            try write("tracked.swift", changed.joined(separator: "\n") + "\n")
            let snapshot = try load()
            let file = try XCTUnwrap(snapshot.files.first)
            XCTAssertEqual(file.hunks.count, 1)
            let hunk = try XCTUnwrap(file.hunks.first)
            XCTAssertTrue(hunk.oldRange?.isEmpty == true || hunk.newRange?.isEmpty == true)
            var oldNumbers = hunk.lines.compactMap(\.oldNumber)
            var newNumbers = hunk.lines.compactMap(\.newNumber)
            for section in file.unchangedSections {
                let pairs = try repo.unchangedLines(snapshot: snapshot, file: file, section: section)
                oldNumbers += pairs.compactMap { $0.old?.oldNumber }
                newNumbers += pairs.compactMap { $0.new?.newNumber }
            }
            XCTAssertEqual(oldNumbers.sorted(), Array(1...original.count))
            XCTAssertEqual(newNumbers.sorted(), Array(1...changed.count))
        }
    }

    func testUnchangedSectionDetectsChangedFinalNewlineInsideLastHunk() throws {
        _ = try repo.git(["config", "core.autocrlf", "false"])
        let original = (1...15).map { "line \($0)\r" }
        try write("tracked.swift", original.joined(separator: "\n") + "\n")
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "context"])
        var changed = original
        changed[14] = "last changed\r"
        for ending in ["", "\n"] {
            let source = changed.joined(separator: "\n")
            try write("tracked.swift", source + ending)
            let snapshot = try load()
            let file = try XCTUnwrap(snapshot.files.first)
            let first = try XCTUnwrap(file.unchangedSections.first)
            XCTAssertFalse(try repo.unchangedLines(snapshot: snapshot, file: file, section: first).isEmpty)
            let last = try XCTUnwrap(file.unchangedSections.last)
            XCTAssertTrue(try repo.unchangedLines(snapshot: snapshot, file: file, section: last).isEmpty)
            try write("tracked.swift", source + (ending.isEmpty ? "\n" : ""))
            XCTAssertThrowsError(try repo.unchangedLines(snapshot: snapshot, file: file, section: first))
        }
    }

    func testCrossExtensionRenameFoldsImportsUsingEachOriginalLanguage() throws {
        // The old-only deletion must still be recognized when the new extension
        // is not a language that supports folding.
        try write("original.go", "import \"old\"\n" + (1...30).map { "// line \($0)\n" }.joined())
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "Go source"])
        _ = try repo.git(["mv", "original.go", "renamed.txt"])
        try write("renamed.txt", (1...30).map { "// line \($0)\n" }.joined())
        let snapshot = try load()
        let file = try XCTUnwrap(snapshot.files.first { $0.path == "renamed.txt" })
        XCTAssertEqual(file.oldPath, "original.go")
        let folded = try repo.contextPresentation(snapshot: snapshot, file: file).flatMap { row -> [DiffPair] in
            if case .imports(let pairs) = row { return pairs }; return []
        }
        XCTAssertEqual(folded.compactMap { $0.old?.text }, ["import \"old\""])
    }

    func testUnchangedSectionsUseGitCanonicalLineEndingsWithoutWritingObjectsOrIndex() throws {
        _ = try repo.git(["config", "core.autocrlf", "input"])
        let original = (1...20).map { "line \($0)" }
        try write("tracked.swift", original.joined(separator: "\n") + "\n")
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "canonical LF"])
        var changed = original
        changed[14] = "changed 15"
        let workingSource = changed.joined(separator: "\r\n") + "\r\n"
        try write("tracked.swift", workingSource)
        let snapshot = try load()
        let file = try XCTUnwrap(snapshot.files.first { $0.path == "tracked.swift" })
        let indexBefore = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let objectsBefore = try repo.git(["count-objects", "-v"]).text
        for section in file.unchangedSections {
            let pairs = try repo.unchangedLines(snapshot: snapshot, file: file, section: section)
            for pair in pairs {
                XCTAssertEqual(pair.new?.text, original[try XCTUnwrap(pair.old?.oldNumber) - 1])
            }
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), indexBefore)
        XCTAssertEqual(try repo.git(["count-objects", "-v"]).text, objectsBefore)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("tracked.swift"), encoding: .utf8), workingSource)
        changed[0] = "new unreviewed edit"
        try write("tracked.swift", changed.joined(separator: "\r\n") + "\r\n")
        XCTAssertThrowsError(try repo.unchangedLines(snapshot: snapshot, file: file, section: file.unchangedSections[0]))
    }

    func testUnchangedSectionsHonorGitCleanFilters() throws {
        _ = try repo.git(["config", "filter.upper.clean", "tr a-z A-Z"])
        try write(".gitattributes", "tracked.swift filter=upper\n")
        let original = (1...20).map { "line \($0)" }
        try write("tracked.swift", original.joined(separator: "\n") + "\n")
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "clean filter"])
        var changed = original
        changed[14] = "changed 15"
        try write("tracked.swift", changed.joined(separator: "\n") + "\n")
        let snapshot = try load()
        let file = try XCTUnwrap(snapshot.files.first { $0.path == "tracked.swift" })
        let pairs = try repo.unchangedLines(snapshot: snapshot, file: file, section: file.unchangedSections[0])
        XCTAssertEqual(pairs.first?.new?.text, "LINE 1")
        changed[0] = "unreviewed"
        try write("tracked.swift", changed.joined(separator: "\n") + "\n")
        XCTAssertThrowsError(try repo.unchangedLines(snapshot: snapshot, file: file, section: file.unchangedSections[0]))
        _ = try repo.git(["config", "filter.upper.clean", "false"])
        _ = try repo.git(["config", "filter.upper.required", "true"])
        XCTAssertThrowsError(try repo.unchangedLines(snapshot: snapshot, file: file, section: file.unchangedSections[0])) {
            XCTAssertTrue($0.localizedDescription.contains("filter"))
            XCTAssertTrue($0.localizedDescription.contains("failed"))
        }
    }

    func testUnchangedSectionsDoNotApplyRegularFileFiltersToSymlinkTargets() throws {
        _ = try repo.git(["config", "filter.upper.clean", "tr a-z A-Z"])
        try write(".gitattributes", "*.link filter=upper\n")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("old.link").path,
                                                  withDestinationPath: "target-in-lowercase")
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "symlink"])
        _ = try repo.git(["mv", "old.link", "new.link"])
        let snapshot = try load()
        let file = try XCTUnwrap(snapshot.files.first { $0.path == "new.link" })
        let pairs = try repo.unchangedLines(snapshot: snapshot, file: file, section: file.unchangedSections[0])
        XCTAssertEqual(pairs.first?.new?.text, "target-in-lowercase")
    }

    func testUnchangedSectionsHonorGitWorkingTreeEncoding() throws {
        try write(".gitattributes", "tracked.swift working-tree-encoding=UTF-16\n")
        let original = (1...20).map { "line \($0)" }
        let url = root.appendingPathComponent("tracked.swift")
        try XCTUnwrap((original.joined(separator: "\n") + "\n").data(using: .utf16)).write(to: url)
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "UTF16 checkout"])
        var changed = original
        changed[14] = "changed 15"
        let data = try XCTUnwrap((changed.joined(separator: "\n") + "\n").data(using: .utf16))
        try data.write(to: url)
        let snapshot = try load()
        let file = try XCTUnwrap(snapshot.files.first { $0.path == "tracked.swift" })
        let pairs = try repo.unchangedLines(snapshot: snapshot, file: file, section: file.unchangedSections[0])
        XCTAssertEqual(pairs.first?.new?.text, "line 1")
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testMetadataOnlyBinaryRenameDoesNotRenderBinaryContent() throws {
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("old.bin"))
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "binary"])
        _ = try repo.git(["mv", "old.bin", "new.bin"])
        let snapshot = try load()
        let file = try XCTUnwrap(snapshot.files.first { $0.path == "new.bin" })
        for section in file.unchangedSections {
            XCTAssertThrowsError(try repo.unchangedLines(snapshot: snapshot, file: file, section: section)) {
                XCTAssertTrue($0.localizedDescription.contains("binary"))
            }
        }
    }

    func testSourceContextFoldsCompleteGoImportsInWorktreeAndRevisions() throws {
        let path = "imports \"odd\"\t\n.go"
        let prefix = ["package sample", "", "import ("] + (0..<8).map { "    \"package\($0)\"" }
        let oldLines = prefix + ["", "    alias \"old\"", ")", "", "func work() {}"]
        let newLines = prefix + ["", "    alias \"new\"", "    \"extra\"", ")", "", "func work() {}"]
        try write(path, oldLines.joined(separator: "\n") + "\n")
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "imports"])
        try write(path, newLines.joined(separator: "\n") + "\n")
        let worktree = try load()
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "change imports"])
        let committed = try load(base: "HEAD~1", target: "HEAD", mergeBase: false)
        for snapshot in [worktree, committed] {
            let file = try XCTUnwrap(snapshot.files.first { $0.path == path })
            XCTAssertFalse(file.hunks.flatMap(\.lines).contains { $0.text == "import (" })
            let rows = try repo.contextPresentation(snapshot: snapshot, file: file)
            let folded = rows.flatMap { row -> [DiffPair] in
                if case .imports(let pairs) = row { return pairs }; return []
            }
            XCTAssertTrue(folded.contains { $0.new?.text == "    \"extra\"" })
            XCTAssertTrue(folded.contains { $0.old?.text == "    alias \"old\"" })
            XCTAssertTrue(folded.contains { $0.new?.text == ")" })
            XCTAssertFalse(folded.contains { $0.new?.text == "func work() {}" })
            XCTAssertEqual(folded.compactMap { $0.old?.text }, Array(oldLines.dropLast(2)))
            XCTAssertEqual(folded.compactMap { $0.new?.text }, Array(newLines.dropLast(2)))
            XCTAssertEqual(DiffPresentation.sourceRows(folded, layout: .unified).filter {
                $0.pair.old?.kind == .context
            }.count, folded.filter { $0.old?.kind == .context }.count)
        }
    }

    func testContentsPreserveAddedDeletedAndRenamedSidesAndSurfaceFailures() throws {
        try write("removed.go", "import \"removed\"\n")
        try write("original.go", "import \"original\"\n")
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "source files"])
        _ = try repo.git(["mv", "original.go", "renamed.go"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("removed.go"))
        try write("added.go", "import \"added\"\n")
        let snapshot = try load()
        let files = snapshot.files.filter { $0.path.hasSuffix(".go") }
        let contents = try Dictionary(uniqueKeysWithValues: files.map {
            ($0.path, (old: try repo.content(snapshot: snapshot, file: $0, side: .old),
                       new: try repo.content(snapshot: snapshot, file: $0, side: .new)))
        })
        XCTAssertEqual(contents["removed.go"]?.new, "")
        XCTAssertEqual(contents["removed.go"]?.old, "import \"removed\"\n")
        XCTAssertEqual(contents["added.go"]?.old, "")
        XCTAssertEqual(contents["added.go"]?.new, "import \"added\"\n")
        XCTAssertEqual(contents["renamed.go"]?.old, "import \"original\"\n")
        XCTAssertEqual(contents["renamed.go"]?.new, "import \"original\"\n")
        try FileManager.default.removeItem(at: root.appendingPathComponent("added.go"))
        let added = try XCTUnwrap(files.first { $0.path == "added.go" })
        XCTAssertThrowsError(try repo.content(snapshot: snapshot, file: added, side: .new))
    }

    func testGoNamedGitlinkRemainsVisibleWithoutReadingItAsSource() throws {
        let path = "dependency.go"
        let directory = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dependency = GitRepository(path: directory.path)
        _ = try dependency.git(["init", "-b", "main"])
        _ = try dependency.git(["config", "user.email", "test@example.invalid"])
        _ = try dependency.git(["config", "user.name", "Test"])
        _ = try dependency.git(["commit", "--allow-empty", "-m", "first"])
        let first = try dependency.revision("HEAD")
        _ = try repo.git(["update-index", "--add", "--cacheinfo", "160000", first, path])
        _ = try repo.git(["commit", "-m", "add gitlink"])
        let added = try load(base: "HEAD~1", target: "HEAD", mergeBase: false)
        _ = try dependency.git(["commit", "--allow-empty", "-m", "second"])
        let second = try dependency.revision("HEAD")
        let worktree = try load()
        _ = try repo.git(["update-index", "--cacheinfo", "160000", second, path])
        _ = try repo.git(["commit", "-m", "update gitlink"])
        let committed = try load(base: "HEAD~1", target: "HEAD", mergeBase: false)
        // Identical-looking ordinary source remains an ordinary blob.
        try write("ordinary.go", "Subproject commit \(second)\n")
        let ordinary = try XCTUnwrap(load().files.first { $0.path == "ordinary.go" })
        XCTAssertFalse(ordinary.isGitlink)
        _ = try repo.git(["update-index", "--force-remove", path])
        _ = try repo.git(["commit", "-m", "remove gitlink"])
        let deleted = try load(base: "HEAD~1", target: "HEAD", mergeBase: false)

        for snapshot in [added, worktree, committed, deleted] {
            let file = try XCTUnwrap(snapshot.files.first { $0.path == path })
            XCTAssertTrue(file.isGitlink)
            XCTAssertTrue(file.unchangedSections.isEmpty)
            XCTAssertThrowsError(try repo.contextPresentation(snapshot: snapshot, file: file)) {
                XCTAssertTrue($0.localizedDescription.contains("no unchanged sections"))
            }
            let rows = DiffPresentation.rows(for: file)
            let pairs = rows.compactMap { row -> DiffPair? in
                if case .code(let pair) = row { return pair }; return nil
            }
            XCTAssertFalse(pairs.isEmpty)
            XCTAssertEqual(pairs.compactMap(\.old), file.hunks.flatMap(\.lines).filter { $0.kind != .addition })
            XCTAssertEqual(pairs.compactMap(\.new), file.hunks.flatMap(\.lines).filter { $0.kind != .deletion })
        }
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

    func testPullRequestRenamePreservesReviewIdentityAndFileFingerprints() throws {
        try write("tracked.swift", "new content\n")
        _ = try repo.git(["commit", "-am", "change"])
        let original = try repo.load(.init(repository: root.path, base: "HEAD~1", target: "HEAD",
                                           pullRequestURL: "https://github.com/o/r/pull/1",
                                           pullRequestTitle: "Original title"))
        let renamed = try repo.load(.init(repository: root.path, base: "HEAD~1", target: "HEAD",
                                          pullRequestURL: "https://github.com/o/r/pull/1",
                                          pullRequestTitle: "Renamed title"))
        XCTAssertEqual(original.identity, renamed.identity)
        XCTAssertEqual(original.files.map(\.fingerprint), renamed.files.map(\.fingerprint))
        XCTAssertEqual(original.title, "o/r #1 Original title")
        XCTAssertEqual(renamed.title, "o/r #1 Renamed title")
    }

    func testSavedComparisonRequestsDecodeWithoutTitleAndRoundTripWithTitle() throws {
        let legacy = Data(#"{"repository":"/repo","base":"main","target":"feature","mergeBase":true,"pullRequestURL":"https://github.com/o/r/pull/1"}"#.utf8)
        let decoded = try JSONDecoder().decode(ComparisonRequest.self, from: legacy)
        XCTAssertNil(decoded.pullRequestTitle)
        XCTAssertEqual(decoded.pullRequestURL, "https://github.com/o/r/pull/1")
        let titled = ComparisonRequest(repository: decoded.repository, base: decoded.base,
                                       target: decoded.target, mergeBase: decoded.mergeBase,
                                       pullRequestURL: decoded.pullRequestURL, pullRequestTitle: "Actual title")
        XCTAssertEqual(try JSONDecoder().decode(ComparisonRequest.self, from: JSONEncoder().encode(titled)), titled)
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
        XCTAssertNil(snapshot.warning)
    }

    func testPullRequestDiffExcludesLaterBaseChangesEvenWithConflictsAndDirtyUnrelatedCheckout() throws {
        let ancestor = try repo.revision("HEAD")
        _ = try repo.git(["checkout", "-b", "feature"])
        try write("tracked.swift", "pull request edit\n")
        try write("feature.swift", "pull request addition\n")
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "PR changes"])
        let head = try repo.revision("HEAD")
        _ = try repo.git(["checkout", "main"])
        try write("tracked.swift", "conflicting change from another PR\n")
        try write("main.swift", "another merged PR\n")
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "another PR merged"])
        let base = try repo.revision("HEAD")

        // Neither the currently checked-out branch nor any local edits belong to this PR.
        _ = try repo.git(["checkout", "-b", "unrelated"])
        try write("unrelated.swift", "unrelated commit\n")
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "unrelated local branch"])
        try write("staged.swift", "local staged addition\n")
        _ = try repo.git(["add", "staged.swift"])
        try write("tracked.swift", "local unstaged edit\n")
        try write("untracked.swift", "local untracked addition\n")
        _ = try repo.git(["remote", "add", "origin", "https://github.com/owner/repo.git"])
        let refs = try repo.git(["show-ref"]).data
        let branch = try repo.git(["symbolic-ref", "HEAD"]).text
        let status = try repo.git(["status", "--porcelain=v1", "-z"]).data
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))

        let pr = try GitHubPR.parse("https://github.com/owner/repo/pull/123")
        let request = try pr.resolve(localRepository: root.path,
                                     revisions: GitHubPRRevisions(base: base, head: head, title: "PR changes"))
        let snapshot = try repo.load(request)
        XCTAssertEqual(snapshot.baseRevision, ancestor)
        XCTAssertEqual(snapshot.targetRevision, head)
        XCTAssertEqual(snapshot.files.map(\.path), ["feature.swift", "tracked.swift"])
        let edited = try XCTUnwrap(snapshot.files.first { $0.path == "tracked.swift" })
        let lines = edited.hunks.flatMap(\.lines)
        XCTAssertEqual(lines.filter { $0.kind == .deletion }.map(\.text), ["base"])
        XCTAssertEqual(lines.filter { $0.kind == .addition }.map(\.text), ["pull request edit"])
        XCTAssertEqual(try repo.content(snapshot: snapshot, file: edited, side: .old), "base\n")
        XCTAssertEqual(try repo.content(snapshot: snapshot, file: edited, side: .new), "pull request edit\n")

        // A direct base-tip comparison would falsely show the other PR's addition as removed.
        let direct = try load(base: base, target: head, mergeBase: false)
        XCTAssertEqual(direct.files.first { $0.path == "main.swift" }?.status, "D")
        XCTAssertEqual(try repo.git(["show-ref"]).data, refs)
        XCTAssertEqual(try repo.git(["symbolic-ref", "HEAD"]).text, branch)
        XCTAssertEqual(try repo.git(["status", "--porcelain=v1", "-z"]).data, status)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("tracked.swift"), encoding: .utf8),
                       "local unstaged edit\n")
    }

    func testStackedPullRequestUsesItsNonDefaultTargetWithoutIncludingParentChanges() throws {
        _ = try repo.git(["checkout", "-b", "parent"])
        try write("parent.swift", "parent feature\n")
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "parent feature"])
        let ancestor = try repo.revision("HEAD")
        _ = try repo.git(["checkout", "-b", "child"])
        try write("child.swift", "child feature\n")
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "child feature"])
        let head = try repo.revision("HEAD")
        _ = try repo.git(["checkout", "parent"])
        try write("parent-later.swift", "later parent change\n")
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "advance parent"])
        let base = try repo.revision("HEAD")
        _ = try repo.git(["checkout", "main"])
        try write("local.swift", "unrelated working change\n")
        _ = try repo.git(["remote", "add", "origin", "https://github.com/owner/repo.git"])
        let refs = try repo.git(["show-ref"]).data
        let status = try repo.git(["status", "--porcelain=v1", "-z"]).data
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))

        let pr = try GitHubPR.parse("https://github.com/owner/repo/pull/124")
        let request = try pr.resolve(localRepository: root.path,
                                    revisions: GitHubPRRevisions(base: base, head: head, title: "Child feature"))
        let snapshot = try repo.load(request)
        XCTAssertEqual(snapshot.baseRevision, ancestor)
        XCTAssertEqual(snapshot.targetRevision, head)
        XCTAssertEqual(snapshot.files.map(\.path), ["child.swift"])
        XCTAssertNil(snapshot.warning)
        XCTAssertEqual(snapshot.files.reduce(0) { $0 + $1.additions }, 1)
        XCTAssertEqual(snapshot.files.reduce(0) { $0 + $1.deletions }, 0)
        XCTAssertEqual(try load(base: "main", target: head).files.map(\.path), ["child.swift", "parent.swift"])
        XCTAssertEqual(try repo.git(["show-ref"]).data, refs)
        XCTAssertEqual(try repo.git(["status", "--porcelain=v1", "-z"]).data, status)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }

    func testCrissCrossStackedPullRequestWarnsWithoutChangingGitsChosenDiff() throws {
        _ = try repo.git(["checkout", "-b", "parent"])
        try write("parent.swift", "parent feature\n")
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "parent feature"])
        let parentAncestor = try repo.revision("HEAD")
        _ = try repo.git(["checkout", "main"])
        try write("main.swift", "main feature\n")
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "advance main"])
        let mainAncestor = try repo.revision("HEAD")
        _ = try repo.git(["checkout", "parent"])
        _ = try repo.git(["merge", "--no-ff", "-m", "parent merges main", mainAncestor])
        let base = try repo.revision("HEAD")
        _ = try repo.git(["checkout", "-b", "child", mainAncestor])
        _ = try repo.git(["merge", "--no-ff", "-m", "child merges earlier parent", parentAncestor])
        try write("child.swift", "child feature\n")
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "child feature"])
        let head = try repo.revision("HEAD")
        _ = try repo.git(["remote", "add", "origin", "https://github.com/owner/repo.git"])
        let selected = try repo.git(["merge-base", base, head]).text.trimmingCharacters(in: .newlines)
        let pr = try GitHubPR.parse("https://github.com/owner/repo/pull/125")
        let request = try pr.resolve(localRepository: root.path,
                                    revisions: GitHubPRRevisions(base: base, head: head, title: "Child feature"))
        let refs = try repo.git(["show-ref"]).data
        let status = try repo.git(["status", "--porcelain=v1", "-z"]).data
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let snapshot = try repo.load(request)
        XCTAssertEqual(snapshot.baseRevision, selected)
        guard case .multipleMergeBases(let alternatives) = snapshot.warning else {
            return XCTFail("Criss-cross ancestry must explain its ambiguous comparison base.")
        }
        XCTAssertEqual(Set([snapshot.baseRevision] + alternatives), Set([parentAncestor, mainAncestor]))
        XCTAssertEqual(alternatives.count, 1)
        XCTAssertEqual(snapshot.files.map(\.path),
                       selected == parentAncestor ? ["child.swift", "main.swift"] : ["child.swift", "parent.swift"])
        XCTAssertEqual(try load(base: "parent", target: "child").warning, snapshot.warning)
        XCTAssertEqual(try load(base: "parent").warning, snapshot.warning)
        let direct = try load(base: "parent", target: "child", mergeBase: false)
        XCTAssertNil(direct.warning)
        XCTAssertEqual(direct.baseRevision, base)
        XCTAssertEqual(direct.files.map(\.path), ["child.swift"])
        XCTAssertEqual(try repo.git(["show-ref"]).data, refs)
        XCTAssertEqual(try repo.git(["status", "--porcelain=v1", "-z"]).data, status)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
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

    func testIgnoreClassificationUsesWholeSourcesAndPreservesStringChangesAndModes() throws {
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
        XCTAssertEqual(snapshot.files.first { $0.path == "Odd \"path\"\t\n.kt" }?.isWhitespaceAndImportsOnly, true)
        XCTAssertEqual(snapshot.files.first { $0.path == "indent.py" }?.isWhitespaceAndImportsOnly, true)
        for name in ["literal.kt", "raw.kt", "mode.kt"] {
            XCTAssertEqual(snapshot.files.first { $0.path == name }?.isWhitespaceAndImportsOnly, false, name)
        }
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "format changes"])
        let committed = try load(base: "HEAD~1", target: "HEAD", mergeBase: false)
        XCTAssertEqual(committed.files.first { $0.path == "Odd \"path\"\t\n.kt" }?.isWhitespaceAndImportsOnly, true)
    }

    func testCombinedIgnoreUsesCanonicalSourcesAcrossStagedWorktreeAndRevisionComparisons() throws {
        let imports = (0..<25).map { "    member\($0),\n" }.joined()
        let originals = [
            "Odd \"path\"\t\n.kt": "package old\nimport a.One\nimport b.Two\nval value = 1\n",
            "partial.py": "from old import (\n" + imports + ")\nprint('yes')\n",
            "mixed.go": "package example\nimport \"fmt\"\nvar value = 1\n",
            "canonical.go": "package example\nimport \"fmt\"\nvar value = 1\n",
            "rename.kt": "import a.One\nval value = 1\n",
            "added.go": ""
        ]
        try write(".gitattributes", "canonical.go text eol=crlf\n")
        for (name, source) in originals { try write(name, source) }
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "ignore baseline"])
        try write("Odd \"path\"\t\n.kt", "package new\nimport b.Two\nimport c.Three\nval value=1\n")
        _ = try repo.git(["add", "--", "Odd \"path\"\t\n.kt"])
        try write("partial.py", originals["partial.py"]!.replacingOccurrences(of: "member12", with: "replacement"))
        try write("mixed.go", "package changed\nimport \"os\"\nvar value = 2\n")
        try write("canonical.go", "package changed\r\nimport \"os\"\r\nvar   value=1\r\n")
        _ = try repo.git(["mv", "--", "rename.kt", "renamed.kt"])
        try write("added.go", "package added\nimport \"os\"\n")
        try write("untracked.go", "package untracked\nimport \"os\"\n")
        let indexBefore = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let worktree = try load()
        for path in ["Odd \"path\"\t\n.kt", "partial.py", "canonical.go", "added.go"] {
            XCTAssertEqual(worktree.files.first { $0.path == path }?.isWhitespaceAndImportsOnly, true, path)
        }
        for path in ["mixed.go", "renamed.kt", "untracked.go"] {
            XCTAssertEqual(worktree.files.first { $0.path == path }?.isWhitespaceAndImportsOnly, false, path)
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), indexBefore)
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "ignore changes"])
        let revision = try load(base: "HEAD~1", target: "HEAD", mergeBase: false)
        for path in ["Odd \"path\"\t\n.kt", "partial.py", "canonical.go", "added.go"] {
            let live = try XCTUnwrap(worktree.files.first { $0.path == path })
            let committed = try XCTUnwrap(revision.files.first { $0.path == path })
            XCTAssertTrue(committed.isWhitespaceAndImportsOnly, path)
            XCTAssertEqual(live.fingerprint, committed.fingerprint, path)
        }
    }

    func testMixedGofmtChangesBecomeNeutralWithoutHidingAddedCodeOrChangingIdentity() throws {
        try write("format.go", "package example\ntype Data struct {\n Name string\n Age int\n}\n")
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "gofmt baseline"])
        try write("format.go", "package example\ntype Data struct {\n Name   string\n Active bool\n Age    int\n}\n")
        let snapshot = try load()
        let file = try XCTUnwrap(snapshot.files.first { $0.path == "format.go" })
        XCTAssertFalse(file.isWhitespaceAndImportsOnly)
        let raw = DiffPresentation.rows(for: file)
        let originalPairs = raw.compactMap { row -> DiffPair? in
            if case .code(let pair) = row { return pair }
            return nil
        }
        let pairs = DiffPresentation.ignoringWhitespace(in: originalPairs, file: file)
        let name = try XCTUnwrap(pairs.first { $0.new?.text == " Name   string" })
        XCTAssertEqual(name.old?.text, " Name string")
        XCTAssertEqual(name.new?.kind, .context)
        XCTAssertEqual(name.new?.oldNumber, 3)
        XCTAssertEqual(name.new?.newNumber, 3)
        let age = try XCTUnwrap(pairs.first { $0.new?.text == " Age    int" })
        XCTAssertEqual(age.new?.kind, .context)
        XCTAssertEqual(age.new?.oldNumber, 4)
        XCTAssertEqual(age.new?.newNumber, 5)
        let added = try XCTUnwrap(pairs.first { $0.new?.text == " Active bool" })
        XCTAssertEqual(added.new?.kind, .addition)
        XCTAssertNil(added.old)
        XCTAssertEqual(DiffPresentation.sourceRows([age], layout: .unified).first?.pair.new?.text, " Age    int")
        XCTAssertTrue(file.hunks.flatMap(\.lines).contains { $0.kind == .addition && $0.text == " Age    int" })
        XCTAssertNotNil(originalPairs.first { $0.new?.text == " Age    int" && $0.new?.kind == .addition })
        XCTAssertEqual(pairs.compactMap(\.old).map(\.text), originalPairs.compactMap(\.old).map(\.text))
        XCTAssertEqual(pairs.compactMap(\.new).map(\.text), originalPairs.compactMap(\.new).map(\.text))
    }

    func testRepeatedWhitespaceLinesBlanksModesAndImportBoundariesKeepTheirOriginalSides() throws {
        let sources = [
            "repeated.kt": "fun run() {\n if (true) {\n  work()\n }\n}\n",
            "literal.go": "package example\nvar text = `one\n\ntwo`\n",
            "mode.kt": "val value = 1\n",
            "imports.kt": "import old.One\nval value=1\n",
            "moved.kt": "callOne()\ncallTwo()\n",
            "new.go": ""
        ]
        for (path, source) in sources { try write(path, source) }
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "line identities baseline"])
        try write("repeated.kt", "fun run() {\n  if (true) {\n    work()\n\n   }\n }\n")
        try write("literal.go", "package example\nvar text = `one\n \ntwo`\n")
        try write("mode.kt", "val  value=1\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("mode.kt").path)
        try write("imports.kt", "import new.Two\nimport new.Three\nval value = 1\n")
        try write("moved.kt", " callTwo()\n callOne()\n")
        try write("new.go", "package example\n\nvar value = 1\n")
        try write("untracked.go", "package example\n\nvar value = 1\n")
        let snapshot = try load()
        func file(_ path: String) throws -> FileDiff { try XCTUnwrap(snapshot.files.first { $0.path == path }) }
        func pairs(_ file: FileDiff) -> [DiffPair] {
            DiffPresentation.rows(for: file).compactMap {
                if case .code(let pair) = $0 { return pair }
                return nil
            }
        }
        let repeated = try file("repeated.kt")
        let repeatedPairs = DiffPresentation.ignoringWhitespace(in: pairs(repeated), file: repeated)
        XCTAssertEqual(repeatedPairs.compactMap { $0.old?.oldNumber }, pairs(repeated).compactMap { $0.old?.oldNumber })
        XCTAssertEqual(repeatedPairs.compactMap { $0.new?.newNumber }, pairs(repeated).compactMap { $0.new?.newNumber })
        XCTAssertEqual(repeatedPairs.compactMap(\.old).map(\.text), pairs(repeated).compactMap(\.old).map(\.text))
        XCTAssertEqual(repeatedPairs.compactMap(\.new).map(\.text), pairs(repeated).compactMap(\.new).map(\.text))
        for text in ["   }", " }", "    work()"] {
            XCTAssertEqual(repeatedPairs.first { $0.new?.text == text }?.new?.kind, .context, text)
        }
        let blank = try XCTUnwrap(repeatedPairs.first { $0.new?.text == "" && $0.old == nil })
        XCTAssertEqual(blank.new?.kind, .context)
        XCTAssertEqual(blank.new?.newNumber, 4)
        XCTAssertEqual(DiffPresentation.sourceRows([blank], layout: .unified).first?.side, .new)
        let literal = try file("literal.go")
        XCTAssertTrue(literal.whitespaceChanges.isEmpty)
        XCTAssertFalse(literal.isWhitespaceAndImportsOnly)
        let mode = try file("mode.kt")
        XCTAssertFalse(mode.isWhitespaceAndImportsOnly)
        XCTAssertEqual(DiffPresentation.ignoringWhitespace(in: pairs(mode), file: mode).first?.new?.kind, .context)
        let imports = try file("imports.kt")
        let importsPairs = DiffPresentation.ignoringWhitespace(in: pairs(imports), file: imports)
        XCTAssertEqual(importsPairs.first { $0.new?.text == "val value = 1" }?.old?.text, "val value=1")
        XCTAssertEqual(importsPairs.first { $0.new?.text == "val value = 1" }?.new?.kind, .context)
        XCTAssertEqual(importsPairs.compactMap { $0.old?.oldNumber }, pairs(imports).compactMap { $0.old?.oldNumber })
        XCTAssertEqual(importsPairs.compactMap { $0.new?.newNumber }, pairs(imports).compactMap { $0.new?.newNumber })
        XCTAssertEqual(importsPairs.compactMap(\.old).map(\.text), pairs(imports).compactMap(\.old).map(\.text))
        XCTAssertEqual(importsPairs.compactMap(\.new).map(\.text), pairs(imports).compactMap(\.new).map(\.text))
        XCTAssertTrue(try file("moved.kt").whitespaceChanges.isEmpty)
        for path in ["new.go", "untracked.go"] {
            let added = try file(path)
            let neutral = DiffPresentation.ignoringWhitespace(in: pairs(added), file: added)
            XCTAssertEqual(neutral.first { $0.new?.text == "" }?.new?.kind, .context, path)
            XCTAssertEqual(neutral.first { $0.new?.text == "var value = 1" }?.new?.kind, .addition, path)
        }
        // The opposite direction preserves the deleted blank's old-side identity.
        try write("new.go", "")
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "blank removal baseline"])
        try write("repeated.kt", "fun run() {\n  if (true) {\n    work()\n   }\n }\n")
        let removed = try XCTUnwrap(try load().files.first { $0.path == "repeated.kt" })
        let removedPairs = DiffPresentation.ignoringWhitespace(in: pairs(removed), file: removed)
        let deletedBlank = try XCTUnwrap(removedPairs.first { $0.old?.text == "" && $0.new == nil })
        XCTAssertEqual(deletedBlank.old?.kind, .context)
        XCTAssertEqual(deletedBlank.old?.oldNumber, 4)
        XCTAssertEqual(DiffPresentation.sourceRows([deletedBlank], layout: .unified).first?.side, .old)
    }

    func testRepeatedFormattingLinesStayNeutralAlongsideCodeChanges() throws {
        try write("repeated.kt", "a  =1\na=1\nvalue=1\n")
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "repeated candidate baseline"])
        try write("repeated.kt", "a=1\na=1\nvalue=2\n")
        let snapshot = try load()
        let file = try XCTUnwrap(snapshot.files.first { $0.path == "repeated.kt" })
        XCTAssertFalse(file.isWhitespaceAndImportsOnly)
        let original = DiffPresentation.rows(for: file).compactMap { row -> DiffPair? in
            if case .code(let pair) = row { return pair }
            return nil
        }
        let projected = DiffPresentation.ignoringWhitespace(in: original, file: file)
        let formatted = try XCTUnwrap(projected.first { $0.old?.oldNumber == 1 })
        XCTAssertEqual(formatted.new?.newNumber, 1)
        XCTAssertEqual(formatted.new?.kind, .context)
        XCTAssertEqual(projected.compactMap { $0.old?.oldNumber }, original.compactMap { $0.old?.oldNumber })
        XCTAssertEqual(projected.compactMap { $0.new?.newNumber }, original.compactMap { $0.new?.newNumber })
    }

    func testWhitespaceProjectionConservesEachSideThroughRepeatedMovedAndMixedHunks() throws {
        let cases: [(String, String)] = [
            ("a  =1\na=1\nvalue=1\n", "a=1\na=1\nvalue=2\n"),
            ("A ()\nX()\nY()\nX()\nZ(1)\n", "X()\nA()\nY()\nX()\nZ(2)\n"),
            ("start()\n }\n}\nend(1)\n", "start()\n}\n }\nend(2)\n"),
            ("start()\n }\n }\nend(1)\n", "start()\n }\nadded()\n  }\nend(2)\n"),
            ("start()\n\n }\n}\nend()\n", "start()\n }\n\n }\nend()\n"),
            ("start()\nwork ()\n }\n}\nend(1)\n", "start()\nwork()\n  }\n }\nend(2)\n")
        ]
        for (index, texts) in cases.enumerated() { try write("Case\(index).kt", texts.0) }
        _ = try repo.git(["add", "."])
        _ = try repo.git(["commit", "-m", "projection conservation baseline"])
        for (index, texts) in cases.enumerated() { try write("Case\(index).kt", texts.1) }
        for file in try load().files where file.path.hasPrefix("Case") {
            let rows = DiffPresentation.rows(for: file)
            var source: [DiffPair] = []
            for row in rows {
                if case .code(let pair) = row { source.append(pair) }
            }
            let projected = DiffPresentation.ignoringWhitespace(in: source, file: file)
            XCTAssertEqual(projected.compactMap { $0.old?.oldNumber }, source.compactMap { $0.old?.oldNumber }, file.path)
            XCTAssertEqual(projected.compactMap { $0.new?.newNumber }, source.compactMap { $0.new?.newNumber }, file.path)
            XCTAssertEqual(projected.compactMap(\.old).map(\.text), source.compactMap(\.old).map(\.text), file.path)
            XCTAssertEqual(projected.compactMap(\.new).map(\.text), source.compactMap(\.new).map(\.text), file.path)
        }
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
        let revisions = try GitHubPRRevisions(base: String(repeating: "a", count: 40), head: String(repeating: "b", count: 40),
                                            title: "Update code")
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
        let revisions = try GitHubPRRevisions(base: base, head: head, title: "Improve review")
        let request = try pr.resolve(localRepository: root.path, revisions: revisions)
        XCTAssertEqual(request.base, base)
        XCTAssertEqual(request.target, head)
        XCTAssertEqual(request.pullRequestTitle, "Improve review")
        XCTAssertEqual(try repo.load(request).title, "owner/repo #123 Improve review")
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
        let request = try pr.resolve(localRepository: root.path, revisions: GitHubPRRevisions(base: sha, head: sha, title: "Alias"))
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
        let rows = snapshot.files.map { DiffPresentation.rows(for: $0) }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertEqual(rows.reduce(0) { count, rows in
            count + rows.filter { if case .code = $0 { return true }; return false }.count
        }, 30_000)
        XCTAssertEqual(snapshot.files.count, 400)
        XCTAssertEqual(snapshot.files.reduce(0) { $0 + $1.additions }, 30_000)
        XCTAssertEqual(snapshot.files.reduce(0) { $0 + $1.deletions }, 30_000)
        print("Backend stress: 400 files / 30,000 source lines / 60,000 changed diff lines loaded with initial presentation in \(elapsed) seconds")
        XCTAssertEqual(try repo.contextPresentation(snapshot: snapshot, file: snapshot.files[0]).count, 75)
    }

    func testLargeUntrackedReview() throws {
        let contents = (0..<75).map { "val item\($0) = \($0)\n" }.joined()
        for index in 0..<400 { try write("Source\(index).kt", contents) }
        let start = ProcessInfo.processInfo.systemUptime
        let snapshot = try load()
        let rows = snapshot.files.map { DiffPresentation.rows(for: $0) }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertEqual(rows.reduce(0) { count, rows in
            count + rows.filter { if case .code = $0 { return true }; return false }.count
        }, 30_000)
        XCTAssertEqual(snapshot.files.count, 400)
        XCTAssertEqual(snapshot.files.reduce(0) { $0 + $1.additions }, 30_000)
        XCTAssertEqual(snapshot.files.reduce(0) { $0 + $1.deletions }, 0)
        print("Backend untracked stress: 400 files / 30,000 added lines loaded with source presentation in \(elapsed) seconds")
    }
}
