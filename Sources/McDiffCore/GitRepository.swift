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
        if request.mergeBase {
            let head = try target ?? repository.revision("HEAD")
            base = try repository.git(["merge-base", requestedBase, head]).text.trimmingCharacters(in: .newlines)
        } else { base = requestedBase }
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
        files = try repository.classifyFormatting(files, base: base, target: target)
        files.sort {
            let lhs = $0.category == .production && !$0.isRemovalOnly && !$0.isFormattingOnly
            let rhs = $1.category == .production && !$1.isRemovalOnly && !$1.isFormattingOnly
            return lhs == rhs ? $0.path < $1.path : lhs
        }
        let canonical = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let identityFields = request.pullRequestURL.map { [canonical, $0] } ??
            [canonical, request.base, request.target ?? "<worktree>", request.mergeBase ? "merge-base" : "direct"]
        let identity = ReviewStore.digest(String(data: try JSONEncoder().encode(identityFields), encoding: .utf8)!)
        let title: String
        if let url = request.pullRequestURL {
            let pr = try GitHubPR.parse(url)
            title = "\(pr.repositoryKey) #\(pr.number)"
        } else { title = "\(request.base) → \(request.target ?? "Working tree")" }
        return ReviewSnapshot(request: request, identity: identity,
                              title: title,
                              baseRevision: base, targetRevision: target, files: files)
    }

    public func content(snapshot: ReviewSnapshot, file: FileDiff, side: DiffSide) throws -> String {
        if (side == .old && file.status == "A") || (side == .new && file.status == "D") { return "" }
        let relative = try contentPath(file: file, side: side)
        let revision = side == .old ? snapshot.baseRevision : snapshot.targetRevision
        if let revision { return try git(["show", "\(revision):\(relative)"]).text }
        let root = String(try git(["rev-parse", "--show-toplevel"]).text.dropLast())
        return try workingContent(path: relative, root: root)
    }

    /// Reads comparison sides in batches without retaining another source cache.
    public func contents(snapshot: ReviewSnapshot, files: [FileDiff]) throws -> [String: (old: String, new: String)] {
        guard !files.isEmpty else { return [:] }
        let oldFiles = files.filter { $0.status != "A" }
        let newFiles = files.filter { $0.status != "D" }
        let old = try blobContents(oldFiles.map { "\(snapshot.baseRevision):\(try contentPath(file: $0, side: .old))" })
        let newPaths = try newFiles.map { try contentPath(file: $0, side: .new) }
        let new: [String]
        if let revision = snapshot.targetRevision {
            new = try blobContents(newPaths.map { "\(revision):\($0)" })
        } else {
            let root = String(try git(["rev-parse", "--show-toplevel"]).text.dropLast())
            new = try newPaths.map { try workingContent(path: $0, root: root) }
        }
        let oldByPath = Dictionary(uniqueKeysWithValues: zip(oldFiles.map(\.path), old))
        let newByPath = Dictionary(uniqueKeysWithValues: zip(newFiles.map(\.path), new))
        return Dictionary(uniqueKeysWithValues: files.map {
            ($0.path, (old: oldByPath[$0.path] ?? "", new: newByPath[$0.path] ?? ""))
        })
    }

    private func contentPath(file: FileDiff, side: DiffSide) throws -> String {
        let relative = side == .old ? file.oldPath : file.path
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."), !relative.contains("\0") else {
            throw GitError("Invalid repository-relative file path.")
        }
        return relative
    }

    private func workingContent(path relative: String, root: String) throws -> String {
        let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        let url = rootURL.appendingPathComponent(relative)
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard parent == rootURL.path || parent.hasPrefix(rootURL.path + "/") else {
            throw GitError("The file's parent directory points outside the repository.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            return try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw GitError("This entry is not a regular file. Its changes are shown in the diff.")
        }
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
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
            hunks = [DiffHunk(header: "@@ -0,0 +1,\(lines.count) @@", lines: lines)]
        }
        return FileDiff(path: relative, status: "A", hunks: hunks, isBinary: binary,
                        fingerprint: fingerprint, category: FileClassifier.classify(relative),
                        hasMetadataChanges: true)
    }

    private func classifyFormatting(_ files: [FileDiff], base: String, target: String?) throws -> [FileDiff] {
        let candidates = files.indices.filter { index in
            let file = files[index]
            guard file.status == "M", !file.isBinary, !file.isGitlink, !file.isFormattingOnly, !file.hasMetadataChanges,
                  !file.hunks.isEmpty, FileClassifier.supportsFormattingComparison(path: file.path) else { return false }
            // Cheap prefilter before retrieving complete blobs; lexical safety is checked below.
            return file.hunks.allSatisfy { hunk in
                let old = hunk.lines.filter { $0.kind == .deletion }.flatMap { $0.text.filter { !$0.isWhitespace } }
                let new = hunk.lines.filter { $0.kind == .addition }.flatMap { $0.text.filter { !$0.isWhitespace } }
                return old == new
            }
        }
        let oldContents = try blobContents(candidates.map { "\(base):\(files[$0].oldPath)" })
        let newContents: [String]
        if let target { newContents = try blobContents(candidates.map { "\(target):\(files[$0].path)" }) }
        else { newContents = try candidates.map { try workingContent(path: files[$0].path, root: path) } }
        var result = files
        for (position, index) in candidates.enumerated() {
            let file = files[index], new = newContents[position]
            // A live worktree may change while loading. Never classify a different version
            // than the one whose changed lines are shown in this snapshot.
            let newLines = new.components(separatedBy: "\n")
            let matches = file.hunks.flatMap(\.lines).allSatisfy { line in
                guard let number = line.newNumber else { return true }
                return number > 0 && number <= newLines.count && newLines[number - 1] == line.text
            }
            guard matches, FileClassifier.isFormattingOnly(path: file.path, oldContent: oldContents[position], newContent: new) else { continue }
            result[index] = FileDiff(path: file.path, oldPath: file.oldPath, status: file.status,
                hunks: file.hunks, isBinary: file.isBinary, fingerprint: file.fingerprint,
                category: file.category, isFormattingOnly: true, hasMetadataChanges: file.hasMetadataChanges,
                isGitlink: file.isGitlink)
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
