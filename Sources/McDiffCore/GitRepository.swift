import Foundation
import CryptoKit

public struct GitError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public struct GitRepository: Sendable {
    public let path: String
    public init(path: String) { self.path = path }

    func git(_ arguments: [String], accepted: Set<Int32> = [0], input: Data? = nil) throws -> ProcessOutput {
        try ProcessRunner.run("git", ["-c", "core.quotePath=true", "-c", "color.ui=false",
                                     "-c", "diff.external=", "-c", "diff.mnemonicPrefix=false",
                                     "-c", "diff.suppressBlankEmpty=false"] + arguments,
                              directory: path, accepted: accepted, input: input)
    }

    public func branches() throws -> [String] {
        try git(["for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes"])
            .text.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/HEAD") }
    }

    public func defaultBase() throws -> String {
        let remote = try git(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], accepted: [0, 1])
        if remote.status == 0 { return remote.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let candidates = try branches()
        for name in ["origin/main", "origin/master", "main", "master"] where candidates.contains(name) { return name }
        return "HEAD"
    }

    func revision(_ ref: String) throws -> String {
        guard !ref.isEmpty, !ref.contains("\0") else { throw GitError("Choose a nonempty Git revision.") }
        return try git(["rev-parse", "--verify", "--end-of-options", "\(ref)^{commit}"])
            .text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func load(_ request: ComparisonRequest) throws -> ReviewSnapshot {
        let root = String(try git(["rev-parse", "--show-toplevel"]).text.dropLast())
        let repository = GitRepository(path: root)
        let requestedBase = try repository.revision(request.base)
        let target = try request.target.map { try repository.revision($0) }
        let base: String
        let warning: ComparisonWarning?
        if request.mergeBase {
            let head = try target ?? repository.revision("HEAD")
            let ancestors = try repository.git(["merge-base", "--all", requestedBase, head])
                .text.split(separator: "\n").map(String.init)
            guard let selected = ancestors.first else { throw GitError("Git returned no common ancestor for this comparison.") }
            base = selected
            warning = ancestors.count > 1 ? .multipleMergeBases(alternatives: Array(ancestors.dropFirst())) : nil
        } else {
            base = requestedBase
            warning = nil
        }
        let options = ["--patch", "--full-index", "--no-ext-diff", "--no-textconv", "--no-color",
                       "--no-relative", "--src-prefix=a/", "--dst-prefix=b/", "--find-renames",
                       "--submodule=short", "--ignore-submodules=none"]
        let patch = try repository.git(["diff"] + options + [base] + (target.map { [$0] } ?? []) + ["--"]).text
        var files = try DiffParser.parse(patch)
        if target == nil {
            let untracked = try repository.git(["ls-files", "--others", "--exclude-standard", "-z"]).data
            for pathData in untracked.split(separator: 0) {
                guard let filePath = String(data: Data(pathData), encoding: .utf8) else {
                    throw GitError("A file path is not valid UTF-8 and cannot be displayed.")
                }
                files.append(try repository.untrackedFile(filePath))
            }
        }
        files = try repository.classifyWhitespaceAndImports(files, base: base)
        files.sort { $0.path < $1.path }
        let canonical = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let identityFields = request.pullRequestURL.map { [canonical, $0] } ??
            [canonical, request.base, request.target ?? "<worktree>", request.mergeBase ? "merge-base" : "direct"]
        let identity = ReviewStore.digest(String(data: try JSONEncoder().encode(identityFields), encoding: .utf8)!)
        let title: String
        if let url = request.pullRequestURL {
            let pr = try GitHubPR.parse(url)
            title = "\(pr.repositoryKey) #\(pr.number)" + (request.pullRequestTitle.map { " \($0)" } ?? "")
        } else { title = "\(request.base) → \(request.target ?? "Working tree")" }
        return ReviewSnapshot(request: request, identity: identity,
                              title: title,
                              baseRevision: base, targetRevision: target, files: files, warning: warning)
    }

    public func content(snapshot: ReviewSnapshot, file: FileDiff, side: DiffSide) throws -> String {
        if (side == .old && file.status == "A") || (side == .new && file.status == "D") { return "" }
        let relative = try contentPath(file: file, side: side)
        let revision = side == .old ? snapshot.baseRevision : snapshot.targetRevision
        if let revision { return try git(["show", "\(revision):\(relative)"]).text }
        let root = String(try git(["rev-parse", "--show-toplevel"]).text.dropLast())
        return try workingContent(path: relative, root: root)
    }

    /// Sources are temporary; resolved context never changes the review identity.
    public func contextPresentation(snapshot: ReviewSnapshot, file: FileDiff) throws -> [PresentedRow] {
        let sources = try validatedContextSources(snapshot: snapshot, file: file)
        return DiffPresentation.rows(for: file, oldSource: sources.oldSource,
                                     newSource: sources.newSource, resolveContext: true)
    }

    public func unchangedLines(snapshot: ReviewSnapshot, file: FileDiff, section: UnchangedSection) throws -> [DiffPair] {
        // Presentation may split an omitted section around imports. Only allow
        // subranges of a genuine omission, with the original old/new offset.
        guard let parent = file.unchangedSections.first(where: { $0.beforeHunkIndex == section.beforeHunkIndex }),
              section.oldStart >= parent.oldStart,
              section.newStart >= parent.newStart,
              section.oldStart - parent.oldStart == section.newStart - parent.newStart,
              section.count.map({ $0 >= 0 }) ?? true else {
            throw GitError("This unchanged section is not part of the loaded review. Refresh the comparison.")
        }
        let sources = try validatedContextSources(snapshot: snapshot, file: file)
        let end = parent.count.map { parent.oldStart + $0 } ?? sources.old.count
        guard section.oldStart <= end else { throw GitError("Invalid unchanged section range. Refresh the comparison.") }
        let count = section.count ?? (end - section.oldStart)
        guard count <= end - section.oldStart else { throw GitError("Invalid unchanged section range. Refresh the comparison.") }
        return (0..<count).map { offset in
            let line = DiffLine(kind: .context, text: sources.old[section.oldStart + offset],
                                oldNumber: section.oldStart + offset + 1,
                                newNumber: section.newStart + offset + 1)
            return DiffPair(old: line, new: line)
        }
    }

    private func validatedContextSources(snapshot: ReviewSnapshot, file: FileDiff) throws
        -> (old: [String], oldSource: String, newSource: String) {
        guard snapshot.files.contains(where: { $0.path == file.path && $0.fingerprint == file.fingerprint }),
              !file.unchangedSections.isEmpty else {
            throw GitError("This file has no unchanged sections in the loaded review. Refresh the comparison.")
        }
        let oldSource = try content(snapshot: snapshot, file: file, side: .old)
        let sources = try canonicalSources(file: file, oldSource: oldSource)
        let expected = sources.newSource
        let stale = GitError("The file changed since this review was loaded. Refresh the comparison before showing unchanged lines.")
        if snapshot.targetRevision == nil {
            let root = String(try git(["rev-parse", "--show-toplevel"]).text.dropLast())
            let repository = GitRepository(path: root)
            let relative = try contentPath(file: file, side: .new)
            let entry = try workingEntry(path: relative, root: root)
            let actualHash: String
            if entry.type == .typeSymbolicLink {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: entry.url.path)
                actualHash = try repository.git(["hash-object", "--no-filters", "--stdin"], input: Data(target.utf8)).text
            } else {
                actualHash = try repository.git(["hash-object", "--", relative]).text
            }
            // Without -w, hash-object neither writes an object nor touches the index.
            let expectedHash = try repository.git(["hash-object", "--no-filters", "--stdin"], input: Data(expected.utf8)).text
            guard actualHash == expectedHash else { throw stale }
        } else {
            let actual = try content(snapshot: snapshot, file: file, side: .new)
            guard actual.utf8.elementsEqual(expected.utf8) else { throw stale }
        }
        return sources
    }

    /// Git's canonical new content is determined by the immutable base and patch,
    /// including clean filters and final-newline changes. No live read is needed.
    private func canonicalSources(file: FileDiff, oldSource: String) throws
        -> (old: [String], oldSource: String, newSource: String) {
        guard !oldSource.utf8.prefix(8000).contains(0) else {
            throw GitError("This file contains binary data and has no unchanged text to display.")
        }
        var old = oldSource.components(separatedBy: "\n")
        if old.last == "" { old.removeLast() }
        let oldHasFinalNewline = oldSource.utf8.last == 10
        let stale = GitError("The file changed since this review was loaded. Refresh the comparison before showing unchanged lines.")
        // Reconstruct the canonical new side from the immutable base and patch.
        // Git verifies the complete live content below, including omitted areas,
        // using its own clean filters rather than approximating normalization.
        var expected = "", oldEnd = 0
        func appendOld(_ range: Range<Int>) {
            for index in range {
                expected += old[index]
                if index + 1 < old.count || oldHasFinalNewline { expected += "\n" }
            }
        }
        for hunk in file.hunks {
            guard let oldRange = hunk.oldRange, let newRange = hunk.newRange,
                  oldRange.lowerBound >= oldEnd, oldRange.upperBound <= old.count else { throw stale }
            appendOld(oldEnd..<oldRange.lowerBound)
            for line in hunk.lines {
                if let number = line.oldNumber {
                    guard number > 0, number <= old.count, old[number - 1].utf8.elementsEqual(line.text.utf8) else { throw stale }
                    if number == old.count {
                        guard oldHasFinalNewline != hunk.noFinalNewlineSides.contains(.old) else { throw stale }
                    }
                }
                if let number = line.newNumber {
                    expected += line.text
                    if number != newRange.upperBound || !hunk.noFinalNewlineSides.contains(.new) { expected += "\n" }
                }
            }
            oldEnd = oldRange.upperBound
        }
        appendOld(oldEnd..<old.count)
        return (old, oldSource, expected)
    }

    private func contentPath(file: FileDiff, side: DiffSide) throws -> String {
        let relative = side == .old ? file.oldPath : file.path
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."), !relative.contains("\0") else {
            throw GitError("Invalid repository-relative file path.")
        }
        return relative
    }

    private func workingEntry(path relative: String, root: String) throws -> (url: URL, type: FileAttributeType) {
        let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        let url = rootURL.appendingPathComponent(relative)
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard parent == rootURL.path || parent.hasPrefix(rootURL.path + "/") else {
            throw GitError("The file's parent directory points outside the repository.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let type = attributes[.type] as? FileAttributeType, type == .typeRegular || type == .typeSymbolicLink else {
            throw GitError("This entry is not a regular file. Its changes are shown in the diff.")
        }
        return (url, type)
    }

    private func workingContent(path relative: String, root: String) throws -> String {
        let entry = try workingEntry(path: relative, root: root)
        if entry.type == .typeSymbolicLink {
            return try FileManager.default.destinationOfSymbolicLink(atPath: entry.url.path)
        }
        return String(decoding: try Data(contentsOf: entry.url), as: UTF8.self)
    }

    private func untrackedFile(_ relative: String) throws -> FileDiff {
        let url = URL(fileURLWithPath: path).appendingPathComponent(relative)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let data: Data, mode: String
        switch attributes[.type] as? FileAttributeType {
        case .typeSymbolicLink:
            data = Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8)
            mode = "120000"
        case .typeRegular:
            data = try Data(contentsOf: url)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            mode = permissions & 0o100 != 0 ? "100755" : "100644"
        default:
            throw GitError("Cannot review untracked entry \(relative): it is not a regular file or symbolic link.")
        }
        let binary = data.prefix(8000).contains(0)
        var hasher = SHA256()
        hasher.update(data: try JSONEncoder().encode([relative, mode]))
        hasher.update(data: data)
        let fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        var hunks: [DiffHunk] = []
        if !binary && !data.isEmpty {
            var texts = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            if texts.last == "" { texts.removeLast() }
            let lines = texts.enumerated().map {
                DiffLine(kind: .addition, text: $0.element, oldNumber: nil, newNumber: $0.offset + 1)
            }
            hunks = [DiffHunk(header: "@@ -0,0 +1,\(lines.count) @@", lines: lines,
                             oldRange: 0..<0, newRange: 0..<lines.count,
                             noFinalNewlineSides: data.last == 10 ? [] : [.new])]
        }
        return FileDiff(path: relative, status: "A", hunks: hunks, isBinary: binary,
                        fingerprint: fingerprint, category: FileClassifier.classify(relative),
                        hasMetadataChanges: true)
    }

    private func classifyWhitespaceAndImports(_ files: [FileDiff], base: String) throws -> [FileDiff] {
        let candidates = files.indices.filter { index in
            let file = files[index]
            guard !file.isBinary, !file.isGitlink,
                  !file.hunks.isEmpty, FileClassifier.supportsWhitespaceAndImportsComparison(path: file.path) else { return false }
            let wholeFileCandidate = file.status == "M" && !file.hasMetadataChanges &&
                DiffPresentation.mayBeWhitespaceAndImportsOnly(file)
            return wholeFileCandidate || DiffPresentation.mayHaveWhitespaceLines(file)
        }
        var result = files
        // Bound the simultaneous full-source working set, including cat-file output.
        for start in stride(from: 0, to: candidates.count, by: 16) {
            let batch = Array(candidates[start..<min(start + 16, candidates.count)])
            let existing = batch.filter { files[$0].status != "A" }
            let contents = try blobContents(existing.map { "\(base):\(files[$0].oldPath)" })
            let oldContents = Dictionary(uniqueKeysWithValues: zip(existing, contents))
            for index in batch {
                let file = files[index]
                let old = file.status == "A" ? "" : oldContents[index]!
                let new = try canonicalSources(file: file, oldSource: old).newSource
                let ignored = FileClassifier.ignoredChanges(file: file, oldContent: old, newContent: new)
                guard ignored.wholeFile || !ignored.lines.isEmpty else { continue }
                result[index] = FileDiff(path: file.path, oldPath: file.oldPath, status: file.status,
                    hunks: file.hunks, isBinary: file.isBinary, fingerprint: file.fingerprint,
                    category: file.category, isWhitespaceAndImportsOnly: ignored.wholeFile, hasMetadataChanges: file.hasMetadataChanges,
                    isGitlink: file.isGitlink, whitespaceChanges: ignored.lines)
            }
        }
        return result
    }

    /// NUL-delimited requests preserve paths containing whitespace and newlines.
    private func blobContents(_ objects: [String]) throws -> [String] {
        guard !objects.isEmpty else { return [] }
        let input = Data((objects.joined(separator: "\0") + "\0").utf8)
        let output = try git(["cat-file", "--batch", "-Z"], input: input)
        let data = output.data
        var offset = 0, contents: [String] = []
        for object in objects {
            guard offset < data.count, let end = data[offset...].firstIndex(of: 0) else {
                throw GitError("Git returned a truncated object header for \(object).")
            }
            let header = String(decoding: data[offset..<end], as: UTF8.self)
            let fields = header.split(separator: " ")
            guard fields.count == 3, fields[1] == "blob", let count = Int(fields[2]), count >= 0,
                  count < data.count - end - 1 else {
                throw GitError("Cannot read Git file \(object): \(header)\n\(output.stderr)")
            }
            let start = end + 1, next = start + count
            guard data[next] == 0 else { throw GitError("Git returned an invalid object terminator for \(object).") }
            contents.append(String(decoding: data[start..<next], as: UTF8.self))
            offset = next + 1
        }
        guard offset == data.count else { throw GitError("Git returned unexpected trailing object data.") }
        return contents
    }
}
