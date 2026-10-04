import Foundation

public enum DiffSide: String, Codable, Sendable { case old, new }
public enum LineKind: String, Codable, Sendable { case context, addition, deletion }

public struct DiffLine: Sendable, Equatable {
    public let kind: LineKind
    public let text: String
    public let oldNumber: Int?
    public let newNumber: Int?
    public init(kind: LineKind, text: String, oldNumber: Int?, newNumber: Int?) {
        self.kind = kind; self.text = text; self.oldNumber = oldNumber; self.newNumber = newNumber
    }
}

public struct DiffHunk: Sendable, Equatable {
    public let header: String
    public let lines: [DiffLine]
    /// Zero-based source ranges, including the insertion point for an empty side.
    public let oldRange: Range<Int>?
    public let newRange: Range<Int>?
    public let noFinalNewlineSides: Set<DiffSide>
    public init(header: String, lines: [DiffLine], oldRange: Range<Int>? = nil, newRange: Range<Int>? = nil,
                noFinalNewlineSides: Set<DiffSide> = []) {
        self.header = header; self.lines = lines
        self.oldRange = oldRange; self.newRange = newRange
        self.noFinalNewlineSides = noFinalNewlineSides
    }
}

public struct UnchangedSection: Identifiable, Hashable, Sendable {
    /// Import runs can split one hunk gap into several independently controlled sections.
    public var id: Int { oldStart }
    public let beforeHunkIndex: Int
    public let oldStart: Int
    public let newStart: Int
    /// nil means the remainder of the file, whose length is resolved on demand.
    public let count: Int?
    public init(beforeHunkIndex: Int, oldStart: Int, newStart: Int, count: Int?) {
        self.beforeHunkIndex = beforeHunkIndex
        self.oldStart = oldStart
        self.newStart = newStart
        self.count = count
    }
}

public enum FileCategory: String, Codable, Sendable, CaseIterable {
    case production, tests, documentation, generated
}

public struct FileDiff: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let oldPath: String
    public let status: String
    public let hunks: [DiffHunk]
    public let isBinary: Bool
    /// At least one comparison side is a Git commit link, not file source.
    public let isGitlink: Bool
    public let fingerprint: String
    public let category: FileCategory
    public let isFormattingOnly: Bool
    public let hasMetadataChanges: Bool
    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .addition }.count } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .deletion }.count } }
    public var isRemovalOnly: Bool { status == "D" || (additions == 0 && deletions > 0) }
    public var unchangedSections: [UnchangedSection] {
        guard status != "A", status != "D", !isBinary, !isGitlink,
              !hunks.isEmpty || hasMetadataChanges else { return [] }
        var result: [UnchangedSection] = []
        var oldEnd = 0, newEnd = 0
        for (index, hunk) in hunks.enumerated() {
            guard let old = hunk.oldRange, let new = hunk.newRange,
                  old.lowerBound >= oldEnd, new.lowerBound >= newEnd,
                  old.lowerBound - oldEnd == new.lowerBound - newEnd else { return [] }
            let count = old.lowerBound - oldEnd
            if count > 0 {
                result.append(UnchangedSection(beforeHunkIndex: index, oldStart: oldEnd, newStart: newEnd, count: count))
            }
            oldEnd = old.upperBound; newEnd = new.upperBound
        }
        result.append(UnchangedSection(beforeHunkIndex: hunks.count, oldStart: oldEnd, newStart: newEnd, count: nil))
        return result
    }
    public init(path: String, oldPath: String? = nil, status: String = "M", hunks: [DiffHunk],
                isBinary: Bool = false, fingerprint: String, category: FileCategory = .production,
                isFormattingOnly: Bool = false, hasMetadataChanges: Bool = false, isGitlink: Bool = false) {
        self.path = path; self.oldPath = oldPath ?? path; self.status = status; self.hunks = hunks
        self.isBinary = isBinary; self.fingerprint = fingerprint; self.category = category
        self.isFormattingOnly = isFormattingOnly
        self.hasMetadataChanges = hasMetadataChanges
        self.isGitlink = isGitlink
    }
}

public struct ComparisonRequest: Codable, Equatable, Sendable {
    public let repository: String
    public let base: String
    /// nil means the live worktree; a value means an explicit revision comparison.
    public let target: String?
    public let mergeBase: Bool
    public let pullRequestURL: String?
    public let pullRequestTitle: String?
    public init(repository: String, base: String, target: String? = nil, mergeBase: Bool = true,
                pullRequestURL: String? = nil, pullRequestTitle: String? = nil) {
        self.repository = repository; self.base = base; self.target = target
        self.mergeBase = mergeBase; self.pullRequestURL = pullRequestURL
        self.pullRequestTitle = pullRequestTitle
    }
}

public struct ReviewSnapshot: Sendable {
    public let request: ComparisonRequest
    public let identity: String
    public let title: String
    public let baseRevision: String
    public let targetRevision: String?
    public let files: [FileDiff]
    public init(request: ComparisonRequest, identity: String, title: String, baseRevision: String,
                targetRevision: String?, files: [FileDiff]) {
        self.request = request; self.identity = identity; self.title = title
        self.baseRevision = baseRevision; self.targetRevision = targetRevision; self.files = files
    }
}

public struct ReviewComment: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var path: String
    public var side: DiffSide
    public var startLine: Int
    public var endLine: Int
    public var text: String
    public var fingerprint: String
    public init(id: UUID = UUID(), path: String, side: DiffSide, startLine: Int, endLine: Int,
                text: String, fingerprint: String) {
        self.id = id; self.path = path; self.side = side; self.startLine = startLine
        self.endLine = endLine; self.text = text; self.fingerprint = fingerprint
    }
}

public struct ReviewProgress: Codable, Sendable {
    /// Only manual review decisions are durable; automatic decisions derive from global filters.
    public var reviewed: [String: String]
    public var comments: [ReviewComment]
    public init(reviewed: [String: String] = [:], comments: [ReviewComment] = []) {
        self.reviewed = reviewed; self.comments = comments
    }
    public mutating func saveComment(_ comment: ReviewComment) throws {
        guard comment.startLine >= 1, comment.endLine >= comment.startLine else {
            throw CommentValidationError.invalidRange
        }
        guard !comment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CommentValidationError.emptyText
        }
        if let conflict = comments.first(where: {
            $0.id != comment.id && $0.path == comment.path && $0.side == comment.side &&
            $0.startLine <= comment.endLine && $0.endLine >= comment.startLine
        }) {
            throw CommentValidationError.overlap(conflict.startLine, conflict.endLine)
        }
        if let index = comments.firstIndex(where: { $0.id == comment.id }) { comments[index] = comment }
        else { comments.append(comment) }
    }
}

public enum CommentValidationError: LocalizedError {
    case invalidRange, emptyText
    case overlap(Int, Int)
    public var errorDescription: String? {
        switch self {
        case .invalidRange: return "Use whole line numbers: start ≥ 1, end ≥ start."
        case .emptyText: return "Enter a comment before saving."
        case .overlap(let start, let end): return "Lines \(start)–\(end) already have a comment. Choose a non-overlapping range or edit that comment."
        }
    }
}

public struct ReviewFilters: Codable, Sendable {
    public var tests: Bool
    public var documentation: Bool
    public var generated: Bool
    public init(tests: Bool = true, documentation: Bool = true, generated: Bool = true) {
        self.tests = tests; self.documentation = documentation; self.generated = generated
    }
    public func skipReason(for file: FileDiff) -> String? {
        if file.isBinary { return "Binary file" }
        if file.isRemovalOnly { return "Removals only" }
        if file.isFormattingOnly { return "Whitespace only" }
        switch file.category {
        case .tests: return tests ? "Tests" : nil
        case .documentation: return documentation ? "Documentation / non-code" : nil
        case .generated: return generated ? "Generated / noise" : nil
        case .production: return nil
        }
    }
}
