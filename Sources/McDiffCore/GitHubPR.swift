import Foundation

public struct GitHubPR: Sendable, Equatable {
    public let repositoryKey: String
    public let url: String
    public let number: Int

    public static func parse(_ value: String) throws -> GitHubPR {
        guard let components = URLComponents(string: value),
              components.scheme == "https", components.host?.lowercased() == "github.com",
              components.user == nil, components.password == nil, components.port == nil else {
            throw GitError("Enter a GitHub pull request URL such as https://github.com/owner/repo/pull/123.")
        }
        let parts = components.path.split(separator: "/").map(String.init)
        let validPart: (String) -> Bool = { !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }
        guard parts.count >= 4, parts[2] == "pull", validPart(parts[0]), validPart(parts[1]),
              let number = Int(parts[3]), number > 0,
              parts.count == 4 || (parts.count == 5 && ["files", "commits", "checks"].contains(parts[4])) else {
            throw GitError("The URL must identify a GitHub pull request.")
        }
        let key = "\(parts[0])/\(parts[1])"
        return GitHubPR(repositoryKey: key, url: "https://github.com/\(key)/pull/\(number)", number: number)
    }

    public func resolve(localRepository: String, revisions: GitHubPRRevisions) throws -> ComparisonRequest {
        let repository = GitRepository(path: localRepository)
        let remotes = try repository.git(["remote"]).text.split(separator: "\n")
        var matchedURL: String?
        for remote in remotes {
            // Repository identity can live in the configured URL or in its insteadOf expansion.
            let configured = try repository.git(["config", "--get-all", "remote.\(remote).url"]).text
            let expanded = try repository.git(["remote", "get-url", "--all", String(remote)]).text
            let urls = (configured + "\n" + expanded).split(separator: "\n")
            if let match = urls.first(where: { Self.remoteKey(String($0))?.lowercased() == repositoryKey.lowercased() }) {
                matchedURL = String(match)
                break
            }
        }
        guard let matchedURL else { throw GitError("This checkout has no GitHub remote for \(repositoryKey). Choose its local repository.") }
        for oid in [revisions.base, revisions.head] {
            let present = try repository.git(["cat-file", "-e", "\(oid)^{commit}"], accepted: [0, 1, 128])
            if present.status != 0 {
                _ = try repository.git(["fetch", "--no-tags", "--no-write-fetch-head", "--no-recurse-submodules",
                                        matchedURL, oid])
            }
            _ = try repository.revision(oid)
        }
        return ComparisonRequest(repository: localRepository, base: revisions.base,
                                 target: revisions.head, mergeBase: true, pullRequestURL: url,
                                 pullRequestTitle: revisions.title)
    }

    private static func remoteKey(_ remote: String) -> String? {
        var path: String
        if remote.hasPrefix("git@github.com:") {
            path = String(remote.dropFirst("git@github.com:".count))
        } else if let url = URLComponents(string: remote), url.host?.lowercased() == "github.com",
                  ["https", "ssh", "git"].contains(url.scheme ?? "") {
            path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else { return nil }
        if path.hasSuffix(".git") { path.removeLast(4) }
        return path
    }
}

public struct GitHubPRRevisions: Sendable, Equatable {
    public let base: String
    public let head: String
    public let title: String

    public init(base: String, head: String, title: String) throws {
        guard [base, head].allSatisfy({ oid in
            [40, 64].contains(oid.count) && oid.allSatisfy { $0.isHexDigit && $0.isASCII }
        }) else { throw GitError("GitHub returned an invalid commit identifier.") }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitHubError.invalidResponse
        }
        self.base = base
        self.head = head
        self.title = title
    }
}
