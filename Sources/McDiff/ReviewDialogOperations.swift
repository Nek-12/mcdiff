import AppKit
import McDiffCore

enum ComparisonInput {
    case pullRequest(String)
    case local(repository: String, base: String, target: String?, mergeBase: Bool)

    func resolve() throws -> (url: String?, request: ComparisonRequest?) {
        switch self {
        case .pullRequest(let value):
            let url = value.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try GitHubPR.parse(url)
            return (url, nil)
        case .local(let repository, let value, let revision, let mergeBase):
            let base = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = revision?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard target != "" else {
                throw GitError("Enter a tag, commit, or ref for the target revision.")
            }
            guard !repository.isEmpty, !base.isEmpty else {
                throw GitError("Choose a repository and enter the revisions to compare.")
            }
            return (nil, ComparisonRequest(repository: repository, base: base, target: target, mergeBase: mergeBase))
        }
    }
}

struct ComparisonBranches: Sendable {
    let branches: [String]
    let defaultBase: String

    static func load(path: String) async throws -> Self {
        let result = try await Task.detached(priority: .userInitiated) {
            let git = GitRepository(path: path)
            return try Self(branches: git.branches(), defaultBase: git.defaultBase())
        }.value
        try Task.checkCancellation()
        return result
    }
}

enum ReviewOutput {
    @MainActor
    static func copy(text: String, pasteboard: NSPasteboard) throws {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw GitError("Could not copy the review. Try Copy again or Export.")
        }
    }

    static func export(text: String, to url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }.value
    }
}
